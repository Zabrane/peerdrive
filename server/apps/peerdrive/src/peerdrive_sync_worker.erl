%% PeerDrive
%% Copyright (C) 2011  Jan Klötzke <jan DOT kloetzke AT freenet DOT de>
%%
%% This program is free software: you can redistribute it and/or modify
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

-module(peerdrive_sync_worker).

-include("store.hrl").
-include("utils.hrl").

-export([start_link/3]).
-export([init/4]).

-record(state, {syncfun, from, to, fromsid, tosid, monitor, numdone,
	numremain, parent}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% External interface...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link(Mode, Store, Peer) ->
	proc_lib:start_link(?MODULE, init, [self(), Mode, Store, Peer]).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% High level store sync logic
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Parent, Mode, FromSId, ToSId) ->
	SyncFun = case Mode of
		ff     -> fun sync_doc_ff/5;
		latest -> fun sync_doc_latest/5;
		merge  -> fun sync_doc_merge/5
	end,
	case peerdrive_volman:store(FromSId) of
		{ok, FromPid} ->
			case peerdrive_volman:store(ToSId) of
				{ok, ToPid} ->
					Id = {FromSId, ToSId},
					{ok, Monitor} = peerdrive_hysteresis:start({sync, FromSId, ToSId}),
					peerdrive_vol_monitor:register_proc(Id),
					proc_lib:init_ack(Parent, {ok, self()}),
					process_flag(trap_exit, true),
					State = #state{
						syncfun   = SyncFun,
						from      = FromPid,
						fromsid   = FromSId,
						to        = ToPid,
						tosid     = ToSId,
						monitor   = Monitor,
						numdone   = 0,
						numremain = 0,
						parent    = Parent
					},
					error_logger:info_report([{sync, start}, {from, FromSId},
						{to, ToSId}]),
					Reason = try
						loop(State, [])
					catch
						throw:Term -> Term
					end,
					error_logger:info_report([{sync, stop}, {from, FromSId},
						{to, ToSId}, {reason, Reason}]),
					peerdrive_hysteresis:stop(Monitor),
					peerdrive_vol_monitor:deregister_proc(Id),
					exit(Reason);

				error ->
					proc_lib:init_ack(Parent, {error, enxio})
			end;

		error ->
			proc_lib:init_ack(Parent, {error, enxio})
	end.


loop(State, OldBacklog) ->
	#state{
		from      = FromStore,
		tosid     = ToSId,
		monitor   = Monitor,
		numdone   = OldDone,
		numremain = OldRemain
	} = State,
	case OldBacklog of
		[] ->
			NewDone = 1,
			Backlog = case peerdrive_store:sync_get_changes(FromStore, ToSId) of
				{ok, Value} -> Value;
				Error       -> throw(Error)
			end,
			NewRemain = length(Backlog),
			case NewRemain of
				0 -> ok;
				_ -> peerdrive_hysteresis:started(Monitor)
			end;

		_  ->
			Backlog    = OldBacklog,
			NewDone    = OldDone + 1,
			NewRemain  = OldRemain
	end,
	case Backlog of
		[Change | NewBacklog] ->
			sync_step(Change, State),
			Timeout = 0,
			case NewBacklog of
				[] -> peerdrive_hysteresis:done(Monitor);
				_  -> peerdrive_hysteresis:progress(Monitor, NewDone * 256 div NewRemain)
			end;

		[] ->
			NewBacklog = [],
			Timeout = infinity
	end,
	loop_check_msg(State#state{numdone=NewDone, numremain=NewRemain}, NewBacklog, Timeout).


loop_check_msg(State, Backlog, Timeout) ->
	#state{
		from    = FromStore,
		fromsid = FromSId,
		tosid   = ToSId,
		parent  = Parent
	} = State,
	receive
		{trigger_mod_doc, FromSId, _Doc} ->
			loop_check_msg(State, Backlog, 0);
		{trigger_rem_store, FromSId} ->
			normal;
		{trigger_rem_store, ToSId} ->
			peerdrive_store:sync_finish(FromStore, ToSId),
			normal;
		{'EXIT', Parent, Reason} ->
			Reason;
		{'EXIT', _, normal} ->
			loop_check_msg(State, Backlog, Timeout);
		{'EXIT', _, Reason} ->
			Reason;

		% deliberately ignore all other messages
		_ -> loop_check_msg(State, Backlog, Timeout)
	after
		Timeout -> loop(State, Backlog)
	end.


sync_step({Doc, SeqNum}, S) ->
	#state{
		syncfun  = SyncFun,
		from     = FromStore,
		to       = ToStore,
		tosid    = ToSId
	} = S,
	sync_doc(Doc, FromStore, ToStore, SyncFun),
	case peerdrive_store:sync_set_anchor(FromStore, ToSId, SeqNum) of
		ok -> ok;
		Error -> throw(Error)
	end.


sync_doc(Doc, From, To, SyncFun) ->
	peerdrive_sync_locks:lock(Doc),
	try
		case peerdrive_store:lookup(To, Doc) of
			{ok, ToRev, _PreRevs} ->
				case peerdrive_store:lookup(From, Doc) of
					{ok, ToRev, _} ->
						% alread the same
						ok;
					{ok, FromRev, _} ->
						SyncFun(Doc, From, FromRev, To, ToRev);
					error ->
						% deleted -> ignore
						ok
				end;
			error ->
				% doesn't exist on destination -> ignore
				ok
		end
	catch
		throw:Term -> Term
	after
		peerdrive_sync_locks:unlock(Doc)
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Functions for fast-forward merge
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


sync_doc_ff(Doc, From, FromRev, To, ToRev) ->
	sync_doc_ff(Doc, From, FromRev, To, ToRev, 3).


sync_doc_ff(_Doc, _From, _NewRev, _To, _OldRev, 0) ->
	{error, econflict};

sync_doc_ff(Doc, From, NewRev, To, OldRev, Tries) ->
	case peerdrive_broker:forward_doc(To, Doc, OldRev, NewRev, From, []) of
		ok ->
			ok;
		{error, econflict} ->
			sync_doc_ff(Doc, From, NewRev, To, OldRev, Tries-1);
		{error, _} = Error ->
			Error
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Functions for automatic merging
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

sync_doc_latest(Doc, From, FromRev, To, ToRev) ->
	sync_doc_merge(Doc, From, FromRev, To, ToRev, fun latest_strategy/6).


sync_doc_merge(Doc, From, FromRev, To, ToRev) ->
	sync_doc_merge(Doc, From, FromRev, To, ToRev, fun merge_strategy/6).


sync_doc_merge(Doc, From, FromRev, To, ToRev, Strategy) ->
	Graph = peerdrive_mergebase:new([FromRev, ToRev], [From, To]),
	try
		case peerdrive_mergebase:ff_head(Graph) of
			{ok, FromRev} ->
				% simple fast forward
				sync_doc_ff(Doc, From, FromRev, To, ToRev);

			{ok, ToRev} ->
				% just the other side was updated -> nothing for us
				ok;

			error ->
				case peerdrive_mergebase:merge_bases(Graph) of
					{ok, BaseRevs} ->
						% FIXME: This assumes that we found the optimal merge
						% base. Currently thats not necessarily the case...
						BaseRev = hd(BaseRevs),
						%% The strategy handler will create a merge commit in
						%% `From'.  The sync_worker will pick it up again and can
						%% simply forward it to the other store via fast-forward.
						Strategy(Doc, From, FromRev, To, ToRev, BaseRev);

					error ->
						% no common ancestor -> must fall back to "latest"
						latest_strategy(Doc, From, FromRev, To, ToRev, undefined)
				end
		end
	after
		peerdrive_mergebase:delete(Graph)
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% 'latest' strategy
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

latest_strategy(Doc, From, FromRev, To, ToRev, _BaseRev) ->
	FromStat = throws(peerdrive_broker:stat(FromRev, [From])),
	ToStat = throws(peerdrive_broker:stat(ToRev, [To])),
	if
		FromStat#rev_stat.mtime >= ToStat#rev_stat.mtime ->
			% worker will pick up again the new merge rev
			Handle = throws(peerdrive_broker:update(From, Doc, FromRev, undefined)),
			try
				throws(peerdrive_broker:merge(Handle, To, ToRev, [])),
				throws(peerdrive_broker:commit(Handle))
			after
				peerdrive_broker:close(Handle)
			end;

		true ->
			% The other revision is newer. The other directions
			% sync_worker will pick it up.
			ok
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% 'simple' strategy
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

merge_strategy(Doc, From, FromRev, To, ToRev, BaseRev) ->
	FromStat = throws(peerdrive_broker:stat(FromRev, [From])),
	ToStat = throws(peerdrive_broker:stat(ToRev, [To])),
	BaseStat = throws(peerdrive_broker:stat(BaseRev, [From, To])),
	TypeSet = sets:from_list([
		BaseStat#rev_stat.type,
		FromStat#rev_stat.type,
		ToStat#rev_stat.type
	]),
	case get_handler_fun(TypeSet) of
		none ->
			% fall back to 'latest' strategy
			latest_strategy(Doc, From, FromRev, To, ToRev, BaseRev);

		HandlerFun ->
			HandlerFun(Doc, From, To, BaseRev, FromRev, ToRev)
	end.


% FIXME: hard coded at the moment
get_handler_fun(TypeSet) ->
	case sets:to_list(TypeSet) of
		[Folder] when Folder =:= <<"org.peerdrive.store">>;
		              Folder =:= <<"org.peerdrive.folder">> ->
			Handlers = orddict:from_list([
				{<<"META">>, fun merge_meta/3},
				{<<"PDSD">>, fun merge_folder/3}
			]),
			fun(Doc, From, To, BaseRev, FromRev, ToRev) ->
				merge(Doc, From, To, BaseRev, FromRev, ToRev, Handlers)
			end;

		_ ->
			none
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Generic merge algoritm
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%
%% TODO: Support addition and removal of whole parts
%%
merge(Doc, From, To, BaseRev, FromRev, ToRev, Handlers) ->
	#rev_stat{parts=FromParts} = throws(peerdrive_broker:stat(FromRev, [From])),
	#rev_stat{parts=ToParts} = throws(peerdrive_broker:stat(ToRev, [To])),
	#rev_stat{parts=BaseParts} = throws(peerdrive_broker:stat(BaseRev, [From, To])),
	OtherParts = ToParts ++ FromParts,

	% Merge only changed parts, except META because we want to update the comment
	Parts = [ FourCC || {FourCC, _Size, Hash} <- BaseParts,
		(FourCC == <<"META">>) orelse
		lists:any(
			fun({F,_,H}) -> (F =:= FourCC) and (H =/= Hash) end,
			OtherParts) ],

	% Read all changed parts
	FromData = merge_read(FromRev, Parts, [From]),
	ToData   = merge_read(ToRev, Parts, [To]),
	BaseData = merge_read(BaseRev, Parts, [From, To]),

	{_Conflict, NewData} = merge_parts(BaseData, FromData, ToData, Handlers,
		false, []),

	% TODO: set a 'conflict' flag in the future?
	merge_write(Doc, From, FromRev, To, ToRev, NewData).


merge_read(_Rev, _Parts, []) ->
	throw({error, enoent});

merge_read(Rev, Parts, [Store | Rest]) ->
	case peerdrive_broker:peek(Store, Rev) of
		{ok, Reader} ->
			try
				[ {Part, merge_read_part(Reader, Part)} || Part <- Parts ]
			after
				peerdrive_broker:close(Reader)
			end;

		{error, enoent} ->
			merge_read(Rev, Parts, Rest);

		Error ->
			throw(Error)
	end.


merge_read_part(Reader, Part) ->
	merge_read_part(Reader, Part, 0, <<>>).


merge_read_part(Reader, Part, Offset, Acc) ->
	case throws(peerdrive_broker:read(Reader, Part, Offset, 16#10000)) of
		<<>> ->
			Acc;
		Data ->
			merge_read_part(Reader, Part, Offset+size(Data),
				<<Acc/binary, Data/binary>>)
	end.


merge_parts([], [], [], _Handlers, Conflicts, Acc) ->
	{Conflicts, Acc};

merge_parts(
		[{Part, Base} | BaseData],
		[{Part, From} | FromData],
		[{Part, To} | ToData],
		Handlers, Conflicts, Acc) ->
	Handler = orddict:fetch(Part, Handlers),
	{NewConflict, Data} = Handler(Base, From, To),
	merge_parts(BaseData, FromData, ToData, Handlers, Conflicts or NewConflict,
		[{Part, Data} | Acc]).


merge_write(Doc, From, FromRev, To, ToRev, NewData) ->
	Writer = throws(peerdrive_broker:update(From, Doc, FromRev,
		<<"org.peerdrive.syncer">>)),
	try
		throws(peerdrive_broker:merge(Writer, To, ToRev, [])),
		lists:foreach(
			fun({Part, Data}) ->
				throws(peerdrive_broker:truncate(Writer, Part, 0)),
				throws(peerdrive_broker:write(Writer, Part, 0, Data))
			end,
			NewData),
		throws(peerdrive_broker:commit(Writer))
	after
		peerdrive_broker:close(Writer)
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Content handlers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

merge_meta(Base, From, To) ->
	case peerdrive_struct:merge(decode(Base), [decode(From), decode(To)]) of
		{ok, Data} ->
			{false, peerdrive_struct:encode(merge_update_meta(Data))};
		{econflict, Data} ->
			{true, peerdrive_struct:encode(merge_update_meta(Data))};
		error ->
			throw({error, eio})
	end.


merge_folder(RawBase, RawFrom, RawTo) ->
	Base = folder_make_gb_tree(decode(RawBase)),
	From = folder_make_gb_tree(decode(RawFrom)),
	To   = folder_make_gb_tree(decode(RawTo)),
	{Conflict, New} = case peerdrive_struct:merge(Base, [From, To]) of
		{ok, Data} ->
			{false, Data};
		{econflict, Data} ->
			{true, Data};
		error ->
			throw({error, eio})
	end,
	{Conflict, peerdrive_struct:encode(gb_trees:values(New))}.


folder_make_gb_tree(Folder) ->
	lists:foldl(
		fun(Entry, Acc) ->
			gb_trees:enter(gb_trees:get(<<>>, Entry), Entry, Acc)
		end,
		gb_trees:empty(),
		Folder).


decode(Data) ->
	try
		peerdrive_struct:decode(Data)
	catch
		error:_ ->
			throw({error, eio})
	end.


%% update comment
merge_update_meta(Data) ->
	update_meta_field(
		[<<"org.peerdrive.annotation">>, <<"comment">>],
		<<"<<Synchronized by system>>">>,
		Data).


update_meta_field([Key], Value, Meta) when ?IS_GB_TREE(Meta) ->
	gb_trees:enter(Key, Value, Meta);

update_meta_field([Key | Path], Value, Meta) when ?IS_GB_TREE(Meta) ->
	NewValue = case gb_trees:lookup(Key, Meta) of
		{value, OldValue} -> update_meta_field(Path, Value, OldValue);
		none              -> update_meta_field(Path, Value, gb_trees:empty())
	end,
	gb_trees:enter(Key, NewValue, Meta);

update_meta_field(_Path, _Value, Meta) ->
	Meta. % Path conflicts with existing data


throws(BrokerResult) ->
	case BrokerResult of
		{error, _Reason} = Error ->
			throw(Error);
		{ok, Result} ->
			Result;
		ok ->
			ok
	end.

