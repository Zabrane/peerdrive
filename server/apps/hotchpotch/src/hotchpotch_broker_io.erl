%% Hotchpotch
%% Copyright (C) 2011  Jan Klötzke <jan DOT kloetzke AT freenet DOT de>
%%
%% This program is free software: you can redistribute_write it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% This program is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with this program.  If not, see <http://www.gnu.org/licenses/>.

-module(hotchpotch_broker_io).
-behaviour(gen_server).

-export([start/1]).
-export([read/4, write/4, truncate/3, get_parents/1, set_parents/2, get_type/1,
	set_type/2, commit/1, suspend/1, close/1]).

-export([init/1, init/2, handle_call/3, handle_cast/2, code_change/3,
	handle_info/2, terminate/2]).

-record(state, {handles, user, doc, stores}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Public broker operations...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(Operation) ->
	proc_lib:start_link(?MODULE, init, [self(), Operation]).

read(Broker, Part, Offset, Length) ->
	gen_server:call(Broker, {read, Part, Offset, Length}, infinity).

write(Broker, Part, Offset, Data) ->
	gen_server:call(Broker, {write, Part, Offset, Data}, infinity).

truncate(Broker, Part, Offset) ->
	gen_server:call(Broker, {truncate, Part, Offset}, infinity).

get_parents(Broker) ->
	gen_server:call(Broker, get_parents, infinity).

set_parents(Broker, Parents) ->
	gen_server:call(Broker, {set_parents, Parents}, infinity).

get_type(Broker) ->
	gen_server:call(Broker, get_type, infinity).

set_type(Broker, Type) ->
	gen_server:call(Broker, {set_type, Type}, infinity).

commit(Broker) ->
	gen_server:call(Broker, commit, infinity).

suspend(Broker) ->
	gen_server:call(Broker, suspend, infinity).

close(Broker) ->
	gen_server:call(Broker, close, infinity).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server callbacks...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Parent, Operation) ->
	case init_operation(Operation) of
		{ok, ErrInfo, State} ->
			proc_lib:init_ack(Parent, {ok, ErrInfo, self()}),
			process_flag(trap_exit, true),
			link(Parent),
			gen_server:enter_loop(?MODULE, [], State#state{user=Parent});

		{error, _Reason, _ErrInfo} = Error ->
			proc_lib:init_ack(Parent, Error),
			Error
	end.


init_operation({peek, Rev, Stores}) ->
	do_peek(Rev, Stores);

init_operation({create, Doc, Type, Creator, Stores}) ->
	do_create(Doc, Type, Creator, Stores);

init_operation({fork, Doc, StartRev, Creator, Stores}) ->
	do_fork(Doc, StartRev, Creator, Stores);

init_operation({update, Doc, StartRev, Creator, Stores}) ->
	do_update(Doc, StartRev, Creator, Stores);

init_operation({resume, Doc, PreRev, Creator, Stores}) ->
	do_resume(Doc, PreRev, Creator, Stores).


handle_call({read, Part, Offset, Length}, _From, S) ->
	make_reply(distribute_read(
		fun(Handle) -> hotchpotch_store:read(Handle, Part, Offset, Length) end,
		S));

handle_call({write, Part, Offset, Data}, _From, S) ->
	make_reply(distribute_write(
		fun(Handle) -> hotchpotch_store:write(Handle, Part, Offset, Data) end,
		S));

handle_call({truncate, Part, Offset}, _From, S) ->
	make_reply(distribute_write(
		fun(Handle) -> hotchpotch_store:truncate(Handle, Part, Offset) end,
		S));

handle_call(get_parents, _From, S) ->
	make_reply(distribute_read(
		fun(Handle) -> hotchpotch_store:get_parents(Handle) end,
		S));

handle_call({set_parents, Parents}, _From, S) ->
	make_reply(distribute_write(
		fun(Handle) -> hotchpotch_store:set_parents(Handle, Parents) end,
		S));

handle_call(get_type, _From, S) ->
	make_reply(distribute_read(
		fun(Handle) -> hotchpotch_store:get_type(Handle) end,
		S));

handle_call({set_type, Type}, _From, S) ->
	make_reply(distribute_write(
		fun(Handle) -> hotchpotch_store:set_type(Handle, Type) end,
		S));

handle_call(commit, _From, S) ->
	do_commit(fun hotchpotch_store:commit/2, S);

handle_call(suspend, _From, S) ->
	do_commit(fun hotchpotch_store:suspend/2, S);

handle_call(close, _From, S) ->
	do_close(S#state.handles),
	{stop, normal, {ok, []}, S}.


handle_info({'EXIT', From, Reason}, #state{user=User} = S) ->
	case From of
		User ->
			% upstream process died
			do_close(S#state.handles),
			{stop, normal, S};

		_Handle ->
			% one of the handles died, abnormally?
			case Reason of
				% don't care
				normal   -> {noreply, S};
				shutdown -> {noreply, S};

				Abnormal ->
					% well, this one was unexpected...
					error_logger:warning_msg("broker_io: handle died: ~p~n",
						[Abnormal]),
					Handles = lists:filter(
						fun({_, N}) -> is_process_alive(N) end,
						S#state.handles),
					{noreply, S#state{handles=Handles}}
			end
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Stubs...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


init(_) -> {stop, enotsup}.
handle_cast(_, State)    -> {stop, enotsup, State}.
code_change(_, State, _) -> {ok, State}.
terminate(_, _)          -> ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Local functions...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

do_peek(Rev, Stores) ->
	do_peek_loop(Rev, Stores, []).


do_peek_loop(_Rev, [], Errors) ->
	hotchpotch_broker:consolidate_error(Errors);

do_peek_loop(Rev, [{Guid, Pid} | Stores], Errors) ->
	case hotchpotch_store:peek(Pid, Rev) of
		{ok, Handle} ->
			State = #state{ handles=[{Guid, Handle}] },
			hotchpotch_broker:consolidate_success(Errors, State);
		{error, Reason} ->
			do_peek_loop(Rev, Stores, [{Guid, Reason} | Errors])
	end.


do_create(Doc, Type, Creator, Stores) ->
	start_handles(
		fun(Pid) -> hotchpotch_store:create(Pid, Doc, Type, Creator) end,
		Doc,
		Stores).


do_fork(Doc, StartRev, Creator, Stores) ->
	start_handles(
		fun(Pid) -> hotchpotch_store:fork(Pid, Doc, StartRev, Creator) end,
		Doc,
		Stores).


do_update(Doc, StartRev, Creator, Stores) ->
	start_handles(
		fun(Pid) -> hotchpotch_store:update(Pid, Doc, StartRev, Creator) end,
		Doc,
		Stores).


do_resume(Doc, PreRev, Creator, Stores) ->
	start_handles(
		fun(Pid) -> hotchpotch_store:resume(Pid, Doc, PreRev, Creator) end,
		Doc,
		Stores).


do_commit(Fun, S) ->
	Reply = case do_commit_prepare(S) of
		{ok, ErrInfo, S2} ->
			merge_errors(do_commit_store(Fun, S2), ErrInfo);

		Error ->
			Error
	end,
	make_reply(Reply).


do_commit_prepare(S) ->
	case distribute_read(fun read_rev_refs/1, S) of
		{ok, ErrInfo, {DocRefs, RevRefs}, S2} ->
			merge_errors(
				distribute_write(
					fun(H) -> hotchpotch_store:set_links(H, DocRefs, RevRefs) end,
					S2),
				ErrInfo);

		Error ->
			Error
	end.


do_commit_store(Fun, S) ->
	Mtime = hotchpotch_util:get_time(),
	{Revs, RWHandles, ROHandles, Errors} = lists:foldl(
		fun({Store, StoreHandle}=Handle, {AccRevs, AccRW, AccRO, AccErrors}) ->
			case Fun(StoreHandle, Mtime) of
				{ok, Rev} ->
					{[Rev|AccRevs], AccRW, [Handle|AccRO], AccErrors};
				{error, Reason} ->
					{AccRevs, [Handle|AccRW], AccRO, [{Store, Reason}|AccErrors]}
			end
		end,
		{[], [], [], []},
		S#state.handles),
	case lists:usort(Revs) of
		[Rev] ->
			% as expected
			do_close(RWHandles),
			{ok, Errors, Rev, S#state{handles=ROHandles}};

		[] when ROHandles =:= [] ->
			% no writer commited...
			{error, Errors, S#state{handles=RWHandles}};

		RevList ->
			% internal error: handles did not came to the same revision! WTF?
			error_logger:error_report([
				{module, ?MODULE},
				{error, 'revision discrepancy'},
				{doc, hotchpotch_util:bin_to_hexstr(S#state.doc)},
				{revs, lists:map(fun hotchpotch_util:bin_to_hexstr/1, RevList)},
				{committers, lists:map(fun({G,_}) -> hotchpotch_util:bin_to_hexstr(G) end, ROHandles)}
			]),
			do_close(ROHandles),
			do_close(RWHandles),
			{
				error,
				lists:map(fun({Store, _}) -> {Store, einternal} end, ROHandles),
				S#state{handles=[]}
			}
	end.


do_close(Handles) ->
	lists:foreach(fun({_Guid, Handle}) -> hotchpotch_store:close(Handle) end, Handles).


start_handles(Fun, Doc, Stores) ->
	case start_handles_loop(Fun, Stores, [], []) of
		{ok, ErrInfo, Handles} ->
			{
				ok,
				ErrInfo,
				#state{
					doc     = Doc,
					handles = Handles,
					stores  = Stores
				}
			};
		Error ->
			Error
	end.


start_handles_loop(_Fun, [], Handles, Errors) ->
	case Handles of
		[] -> hotchpotch_broker:consolidate_error(Errors);
		_  -> hotchpotch_broker:consolidate_success(Errors, Handles)
	end;

start_handles_loop(Fun, [{Guid, Pid} | Stores], Handles, Errors) ->
	case Fun(Pid) of
		{ok, Handle} ->
			start_handles_loop(Fun, Stores, [{Guid, Handle} | Handles], Errors);
		{error, Reason} ->
			start_handles_loop(Fun, Stores, Handles, [{Guid, Reason} | Errors])
	end.


distribute_read(Fun, S) ->
	case S#state.handles of
		[] ->
			{error, enoent, []};

		[{Guid, Handle} | _] ->
			% TODO: ask more than just the first store if it fails...
			case Fun(Handle) of
				{ok, Result}    -> {ok, [], Result, S};
				{error, Reason} -> {error, [{Guid, Reason}], S}
			end
	end.


distribute_write(Fun, S) ->
	% TODO: parallelize this loop
	{Success, Fail} = lists:foldr(
		fun({Store, Handle}, {AccSuccess, AccFail}) ->
			case Fun(Handle) of
				ok ->
					{[{Store, Handle} | AccSuccess], AccFail};

				{error, Reason} ->
					{AccSuccess, [{Store, Reason, Handle} | AccFail]}
			end
		end,
		{[], []},
		S#state.handles),

	% let's see what we got...
	case Success of
		[] ->
			% nobody did anything -> no state change -> keep going
			ErrInfo = lists:map(
				fun({Store, Reason, _}) -> {Store, Reason} end,
				Fail),
			{error, ErrInfo, S};

		_ ->
			% at least someone did what he was told
			ErrInfo = lists:map(
				fun({Store, Reason, Handle}) ->
					hotchpotch_store:close(Handle),
					{Store, Reason}
				end,
				Fail),
			{ok, ErrInfo, S#state{handles=Success}}
	end.


make_reply(Result) ->
	case Result of
		{ok, ErrInfo, State} ->
			{reply, hotchpotch_broker:consolidate_success(ErrInfo), State};

		{ok, ErrInfo, Reply, State} ->
			{reply, hotchpotch_broker:consolidate_success(ErrInfo, Reply), State};

		{error, ErrInfo, State} ->
			{reply, hotchpotch_broker:consolidate_error(ErrInfo), State}
	end.


merge_errors(Result, AddErrors) ->
	case Result of
		{ok, ErrInfo, State} ->
			{ok, AddErrors++ErrInfo, State};

		{ok, ErrInfo, Reply, State} ->
			{ok, AddErrors++ErrInfo, Reply, State};

		{error, ErrInfo, State} ->
			{error, AddErrors++ErrInfo, State}
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Reference reading
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

read_rev_refs(Handle) ->
	try
		{DocSet, RevSet} = lists:foldl(
			fun(FourCC, {AccDocRefs, AccRevRefs}) ->
				{NewDR, NewRR} = read_rev_extract(read_rev_part(Handle,
					FourCC)),
				{sets:union(NewDR, AccDocRefs), sets:union(NewRR, AccRevRefs)}
			end,
			{sets:new(), sets:new()},
			[<<"HPSD">>, <<"META">>]),
		{ok, {sets:to_list(DocSet), sets:to_list(RevSet)}}
	catch
		throw:Term -> Term
	end.


read_rev_part(Handle, Part) ->
	case hotchpotch_store:read(Handle, Part, 0, 16#1000000) of
		{ok, Binary} ->
			case catch hotchpotch_struct:decode(Binary) of
				{'EXIT', _Reason} ->
					[];
				Struct ->
					Struct
			end;

		{error, enoent} ->
			[];

		Error ->
			throw(Error)
	end.


read_rev_extract(Data) when is_record(Data, dict, 9) ->
	dict:fold(
		fun(_Key, Value, {AccDocs, AccRevs}) ->
			{Docs, Revs} = read_rev_extract(Value),
			{sets:union(Docs, AccDocs), sets:union(Revs, AccRevs)}
		end,
		{sets:new(), sets:new()},
		Data);

read_rev_extract(Data) when is_list(Data) ->
	lists:foldl(
		fun(Value, {AccDocs, AccRevs}) ->
			{Docs, Revs} = read_rev_extract(Value),
			{sets:union(Docs, AccDocs), sets:union(Revs, AccRevs)}
		end,
		{sets:new(), sets:new()},
		Data);

read_rev_extract({dlink, Doc}) ->
	{sets:from_list([Doc]), sets:new()};

read_rev_extract({rlink, Rev}) ->
	{sets:new(), sets:from_list([Rev])};

read_rev_extract(_) ->
	{sets:new(), sets:new()}.

