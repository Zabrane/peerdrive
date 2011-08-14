%% Hotchpotch
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

-module(hotchpotch_file_store).
-behaviour(gen_server).

-export([start_link/2, stop/1, fsck/1, gc/1]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3, handle_info/2, terminate/2]).

% Functions used by helper processes (io/forwarder/importer)
-export([commit/4, doc_unlock/2, forward_commit/3, part_get/2, part_lock/2,
	part_put/3, part_unlock/2, put_rev_commit/3, rev_unlock/2, suspend/4,
	tmp_name/1]).

-include("store.hrl").
-include_lib("kernel/include/file.hrl").

-record(state, {
	path,
	sid,
	gen,
	gc_tmr,
	gc_gen,
	doc_tbl,  % ets: {Doc::DId, Rev::RId, [PreRev::RId], Generation}
	rev_tbl,  % ets: {Rev::RId, #revision{}}
	part_tbl, % dets: {Part::PId, Content::binary() | Size::int()}
	peer_tbl, % ets: {Store::Sid, Generation}
	objlocks, % dict: {doc, DId} | {part, PId} -> Count::int()
	synclocks % dict: SId --> pid()
}).

-define(GC_SLACK_TIME, 60*1000). % delay until gc runs (reset on new activity)
-define(GC_MIN_UPDATES, 100).    % gc will be scheduled after this number of updates
-define(GC_MAX_UPDATES, 1000).   % gc is forced after this number of updates

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Server state management...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link(Id, {Path, Name}) ->
	RegId = list_to_atom(atom_to_list(Id) ++ "_store"),
	gen_server:start_link({local, RegId}, ?MODULE, {Id, Path, Name}, []).


init({Id, Path, Name}) ->
	case filelib:is_dir(Path) of
		true ->
			S = #state{
				path      = Path,
				synclocks = dict:new(),
				objlocks  = dict:new()
			},
			S2 = load_store(Id, S),
			S3 = check_root_doc(Name, S2),
			hotchpotch_volman:reg_store(Id, S3#state.sid),
			process_flag(trap_exit, true),
			{ok, S3};

		false ->
			{stop, enoent}
	end.

stop(Store) ->
	gen_server:cast(Store, stop).

fsck(Store) ->
	gen_server:cast(Store, fsck).

gc(Store) ->
	gen_server:call(Store, gc, infinity).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Functions used by helper processes...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

tmp_name(Store) ->
	gen_server:call(Store, tmp_name, infinity).

doc_unlock(Store, DId) ->
	gen_server:cast(Store, {unlock, {doc, DId}}).

rev_unlock(Store, RId) ->
	gen_server:cast(Store, {unlock, {rev, RId}}).

part_lock(Store, PId) ->
	gen_server:call(Store, {lock, {part, PId}}, infinity).

part_unlock(Store, PId) ->
	gen_server:cast(Store, {unlock, {part, PId}}).

part_put(Store, PId, Content) ->
	gen_server:call(Store, {part_put, PId, Content}, infinity).

part_get(Store, PId) ->
	gen_server:call(Store, {part_get, PId}, infinity).

commit(Store, Doc, PreRev, Revision) ->
	gen_server:call(Store, {commit, Doc, PreRev, Revision}, infinity).

suspend(Store, Doc, PreRev, Revision) ->
	gen_server:call(Store, {suspend, Doc, PreRev, Revision}, infinity).

forward_commit(Store, Doc, RevPath) ->
	gen_server:call(Store, {forward_commit, Doc, RevPath}, infinity).

put_rev_commit(Store, RId, Rev) ->
	gen_server:call(Store, {put_rev_commit, RId, Rev}, infinity).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Gen_server callbacks...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_call(guid, _From, S) ->
	{reply, S#state.sid, S};

handle_call(statfs, _From, S) ->
	{reply, do_statfs(S), S};

handle_call({lookup, DId}, _From, S) ->
	case ets:lookup(S#state.doc_tbl, DId) of
		[{_DId, RId, PreRIds, _Gen}] ->
			{reply, {ok, RId, PreRIds}, S};
		[] ->
			{reply, error, S}
	end;

handle_call({contains, RId}, _From, S) ->
	Reply = ets:member(S#state.rev_tbl, RId),
	{reply, Reply, S};

handle_call({stat, Rev}, _From, S) ->
	Reply = do_stat(Rev, S),
	{reply, Reply, S};

handle_call({peek, RId}, From, S) ->
	{User, _} = From,
	{Reply, S2} = do_peek(RId, User, S),
	{reply, Reply, S2};

handle_call({create, DId, Type, Creator}, From, S) ->
	{User, _} = From,
	{Reply, S2} = do_create(DId, Type, Creator, User, S),
	{reply, Reply, S2};

handle_call({fork, DId, StartRId, Creator}, From, S) ->
	{User, _} = From,
	{Reply, S2} = do_fork(DId, StartRId, Creator, User, S),
	{reply, Reply, S2};

handle_call({update, DId, StartRId, Creator}, From, S) ->
	{User, _} = From,
	{Reply, S2} = do_update(DId, StartRId, Creator, User, S),
	{reply, Reply, S2};

handle_call({resume, DId, PreRId, Creator}, From, S) ->
	{User, _} = From,
	{Reply, S2} = do_resume(DId, PreRId, Creator, User, S),
	{reply, Reply, S2};

handle_call({forget, DId, PreRId}, _From, S) ->
	{Reply, S2} = do_forget(DId, PreRId, S),
	{reply, Reply, S2};

handle_call({delete_rev, RId}, _From, S) ->
	{Reply, S2} = do_delete_rev(RId, S),
	{reply, Reply, S2};

handle_call({delete_doc, DId, RId}, _From, S) ->
	{Reply, S2} = do_delete_doc(DId, RId, S),
	{reply, Reply, S2};

handle_call({put_doc, DId, RId}, _From, S) ->
	{Reply, S2} = do_put_doc(DId, RId, S),
	{reply, Reply, S2};

handle_call({forward_doc, DId, RevPath}, {User, _}, S) ->
	{Reply, S2} = do_forward_doc(DId, RevPath, User, S),
	{reply, Reply, S2};

handle_call({put_rev, RId, Rev}, {User, _}, S) ->
	{Reply, S2} = do_put_rev(RId, Rev, User, S),
	{reply, Reply, S2};

handle_call({sync_get_changes, PeerSId}, {Caller, _}, S) ->
	{Reply, S2} = do_sync_get_changes(PeerSId, Caller, S),
	{reply, Reply, S2};

handle_call({sync_set_anchor, PeerSId, SeqNum}, _From, S) ->
	do_sync_set_anchor(PeerSId, SeqNum, S),
	{reply, ok, S};

handle_call({sync_finish, PeerSId}, {Caller, _}, S) ->
	{Reply, S2} = do_sync_finish(PeerSId, Caller, S),
	{reply, Reply, S2};

handle_call(gc, _From, S) ->
	do_gc(S),
	{reply, ok, S};

% internal: lock object
handle_call({lock, ObjId}, _From, S) ->
	S2 = do_lock(ObjId, S),
	{reply, ok, S2};

% internal: generate tmp filename
handle_call(tmp_name, _From, S) ->
	{reply, hotchpotch_util:gen_tmp_name(S#state.path), S};

% internal: commit a new revision
handle_call({commit, DId, PreRId, Rev}, _From, S) ->
	{Reply, S2} = do_commit(DId, PreRId, Rev, S),
	{reply, Reply, S2};

% internal: queue a preliminary revision
handle_call({suspend, DId, PreRId, Rev}, _From, S) ->
	{Reply, S2} = do_suspend(DId, PreRId, Rev, S),
	{reply, Reply, S2};

% internal: ok | {error, Reason}
handle_call({forward_commit, DId, RevPath}, _From, S) ->
	{Reply, S2} = do_forward_doc_commit(DId, RevPath, S),
	{reply, Reply, S2};

% internal: ok | {error, Reason}
handle_call({put_rev_commit, RId, Rev}, _From, S) ->
	{Reply, S2} = do_put_rev_commit(RId, Rev, S),
	{reply, Reply, S2};

% internal: put part into database
handle_call({part_put, PId, Content}, _From, S) ->
	Reply = do_part_put(PId, Content, S),
	{reply, Reply, S};

% internal: get part
handle_call({part_get, PId}, _From, S) ->
	Reply = do_part_get(PId, S),
	{reply, Reply, S}.


% internal: unlock a part
handle_cast({unlock, ObjId}, S) ->
	S2 = do_unlock(ObjId, S),
	{noreply, S2};

handle_cast(fsck, S) ->
	do_fsck(S),
	{noreply, S};

handle_cast(stop, S) ->
	{stop, normal, S}.


handle_info({'EXIT', From, Reason}, S) ->
	case sync_trap_exit(From, S) of
		{ok, S2} ->
			% a sync process went away
			{noreply, S2};

		error ->
			% must be an associated worker process
			case Reason of
				normal   -> {noreply, S};
				shutdown -> {noreply, S};
				_ ->        {stop, {eunexpected, Reason}, S}
			end
	end;

handle_info({timeout, _, gc}, S) ->
	do_gc(S),
	{noreply, S#state{gc_gen=S#state.gen}}.


terminate(_Reason, S) ->
	save_store(clean, S),
	close_store(S).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Stubs...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

code_change(_, State, _) -> {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Service implementations...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

do_statfs(_S) ->
	% TODO: implement
	{ok, #fs_stat{
		bsize  = 4096,
		blocks = 1024,
		bfree  = 1024,
		bavail = 1024
	}}.


do_stat(RId, #state{rev_tbl=RevTbl} = S) ->
	case ets:lookup(RevTbl, RId) of
		[{_, Rev}] ->
			Parts = [ {FourCC, part_size(PId, S), PId} ||
				{FourCC, PId} <- Rev#revision.parts ],
			{ok, #rev_stat{
				flags     = Rev#revision.flags,
				parts     = Parts,
				parents   = Rev#revision.parents,
				mtime     = Rev#revision.mtime,
				type      = Rev#revision.type,
				creator   = Rev#revision.creator,
				doc_links = Rev#revision.doc_links,
				rev_links = Rev#revision.rev_links
			}};

		[] ->
			{error, enoent}
	end.


do_peek(RId, User, #state{rev_tbl=RevTbl} = S) ->
	case ets:lookup(RevTbl, RId) of
		[{_, Rev}] ->
			S2 = lists:foldl(
				fun({_, PId}, AccS) -> do_lock({part, PId}, AccS) end,
				S,
				Rev#revision.parts),
			{ok, _} = Reply = hotchpotch_file_store_io:start_link(Rev, User),
			{Reply, S2};

		[] ->
			{{error, enoent}, S}
	end.


do_create(DId, Type, Creator, User, S) ->
	Rev = #revision{type=Type, creator=Creator},
	start_writer(DId, undefined, Rev, User, S).


do_fork(DId, StartRId, Creator, User, #state{rev_tbl=RevTbl}=S) ->
	case ets:lookup(RevTbl, StartRId) of
		[{_, Rev}] ->
			NewRev = Rev#revision{
				parents = [StartRId],
				creator = Creator
			},
			start_writer(DId, undefined, NewRev, User, S);

		[] ->
			{{error, enoent}, S}
	end.


do_update(DId, StartRId, Creator, User, S) ->
	#state{doc_tbl=DocTbl, rev_tbl=RevTbl} = S,
	case ets:member(DocTbl, DId) of
		true ->
			case ets:lookup(RevTbl, StartRId) of
				[{_, Rev}] ->
					NewCreator = case Creator of
						keep -> Rev#revision.creator;
						_    -> Creator
					end,
					NewRev = Rev#revision{
						parents = [StartRId],
						creator = NewCreator
					},
					start_writer(DId, undefined, NewRev, User, S);

				[] ->
					{{error, enoent}, S}
			end;

		false ->
			{{error, enoent}, S}
	end.


do_resume(DId, PreRId, Creator, User, S) ->
	#state{doc_tbl=DocTbl, rev_tbl=RevTbl} = S,
	case ets:lookup(DocTbl, DId) of
		[{_, _, PreRevs, _}] ->
			case lists:member(PreRId, PreRevs) of
				true ->
					case ets:lookup(RevTbl, PreRId) of
						[{_, Rev}] ->
							NewCreator = case Creator of
								keep -> Rev#revision.creator;
								_    -> Creator
							end,
							NewRev = Rev#revision{creator = NewCreator},
							start_writer(DId, PreRId, NewRev, User, S);

						[] ->
							{{error, enoent}, S}
					end;

				false ->
					{{error, econflict}, S}
			end;

		[] ->
			{{error, enoent}, S}
	end.


do_forget(DId, PreRId, #state{sid=SId, doc_tbl=DocTbl, gen=Gen} = S) ->
	case ets:lookup(DocTbl, DId) of
		[{_, RId, CurPreRIds, _Gen}] ->
			case lists:member(PreRId, CurPreRIds) of
				true ->
					NewPreRIds = [ R || R <- CurPreRIds, R =/= PreRId ],
					hotchpotch_vol_monitor:trigger_mod_doc(SId, DId),
					ets:insert(DocTbl, {DId, RId, NewPreRIds, Gen}),
					{ok, next_gen(S)};

				false ->
					{{error, econflict}, S}
			end;

		[] ->
			{{error, enoent}, S}
	end.


do_delete_rev(RId, #state{sid=SId, rev_tbl=RevTbl} = S) ->
	case ets:member(RevTbl, RId) of
		true ->
			hotchpotch_vol_monitor:trigger_rm_rev(SId, RId),
			ets:delete(RevTbl, RId),
			{ok, next_gen(S)};

		false ->
			{{error, enoent}, S}
	end.


do_delete_doc(DId, RId, #state{doc_tbl=DocTbl, sid=SId} = S) ->
	case DId of
		SId ->
			{{error, eacces}, S};

		_ ->
			case ets:lookup(DocTbl, DId) of
				[{_, RId, _PreRevs, _Gen}] ->
					hotchpotch_vol_monitor:trigger_rm_doc(SId, DId),
					ets:delete(DocTbl, DId),
					{ok, next_gen(S)};

				[{_, _OtherRev, _PreRevs, _Gen}] ->
					{{error, econflict}, S};

				[] ->
					{{error, enoent}, S}
			end
	end.


do_put_doc(DId, RId, #state{doc_tbl=DocTbl, gen=Gen} = S) ->
	case ets:lookup(DocTbl, DId) of
		% document does not exist (yet)...
		[] ->
			hotchpotch_vol_monitor:trigger_add_doc(S#state.sid, DId),
			ets:insert(DocTbl, {DId, RId, [], Gen}),
			{ok, next_gen(S)};

		% already pointing to requested rev
		[{_, RId, _, _}] ->
			{ok, S};

		% completely other rev
		[_] ->
			{{error, econflict}, S}
	end.


do_commit(DId, OldPreRId, Rev, #state{doc_tbl=DocTbl, gen=Gen} = S) ->
	RId = hotchpotch_store:hash_revision(Rev),
	case ets:lookup(DocTbl, DId) of
		[{_, CurrentRId, CurrentPreRIds, _Gen}] ->
			case lists:member(CurrentRId, Rev#revision.parents) of
				true  ->
					NewPreRIds = [R || R <- CurrentPreRIds, R =/= OldPreRId],
					ets:insert(S#state.rev_tbl, {RId, Rev}),
					ets:insert(DocTbl, {DId, RId, NewPreRIds, Gen}),
					hotchpotch_vol_monitor:trigger_mod_doc(S#state.sid, DId),
					{{ok, RId}, next_gen(S)};

				false ->
					{{error, econflict}, S}
			end;

		[] ->
			ets:insert(S#state.rev_tbl, {RId, Rev}),
			ets:insert(DocTbl, {DId, RId, [], Gen}),
			hotchpotch_vol_monitor:trigger_add_doc(S#state.sid, DId),
			{{ok, RId}, next_gen(S)}
	end.


do_suspend(DId, OldPreRId, Rev, #state{doc_tbl=DocTbl, gen=Gen} = S) ->
	RId = hotchpotch_store:hash_revision(Rev),
	case ets:lookup(DocTbl, DId) of
		[{_, CurrentRId, CurrentPreRIds, _Gen}] ->
			NewPreRIds = lists:usort(
				[RId] ++ [R || R <- CurrentPreRIds, R =/= OldPreRId]
			),
			ets:insert(S#state.rev_tbl, {RId, Rev}),
			ets:insert(DocTbl, {DId, CurrentRId, NewPreRIds, Gen}),
			hotchpotch_vol_monitor:trigger_mod_doc(S#state.sid, DId),
			{{ok, RId}, next_gen(S)};

		[] ->
			{{error, enoent}, S}
	end.


do_part_put(PId, Data, #state{part_tbl=PartTbl}) when is_binary(Data) ->
	ok = dets:insert(PartTbl, {PId, Data}),
	ok;

do_part_put(PId, TmpName, #state{part_tbl=PartTbl} = S) ->
	case file:read_file_info(TmpName) of
		{ok, #file_info{size=Size}} ->
			NewName = hotchpotch_util:build_path(S#state.path, PId),
			Placed = filelib:ensure_dir(NewName) == ok andalso
				file:rename(TmpName, NewName) == ok,
			case Placed of
				true ->
					ok = dets:insert(PartTbl, {PId, Size}),
					ok;
				false ->
					{error, eio}
			end;

		{error, _} = Error ->
			Error
	end.


do_part_get(PId, #state{part_tbl=PartTbl} = S) ->
	case dets:lookup(PartTbl, PId) of
		[{_, Data}] when is_binary(Data) ->
			{ok, Data};
		[{_, Size}] when is_integer(Size) ->
			{ok, hotchpotch_util:build_path(S#state.path, PId)};
		[] ->
			{error, enoent}
	end.


% ok | {ok, MissingRevs, Handle} | {error, Reason}
do_forward_doc(DId, RevPath, User, S) when length(RevPath) >= 2 ->
	StartRId = hd(RevPath),
	case ets:lookup(S#state.doc_tbl, DId) of
		[{_, StartRId, _, _}] ->
			RevTbl = S#state.rev_tbl,
			case [RId || RId <- RevPath, not ets:member(RevTbl, RId)] of
				[] ->
					do_forward_doc_commit(DId, RevPath, S);

				Missing ->
					% Some Revs are missing and need to be uploaded. Make sure
					% nothing gets garbage collected in between...
					S2 = lists:foldl(
						fun(RId, AccS) -> do_lock({rev, RId}, AccS) end,
						S,
						RevPath),
					{ok, Handle} = hotchpotch_file_store_fwd:start_link(DId,
						RevPath, User),
					{{ok, Missing, Handle}, S2}
			end;

		[_] ->
			{{error, econflict}, S};
		[] ->
			{{error, enoent}, S}
	end;

do_forward_doc(_DId, _RevPath, _User, S) ->
	{{error, einval}, S}.


do_forward_doc_commit(DId, RevPath, #state{doc_tbl=DocTbl, rev_tbl=RevTbl} = S) ->
	try
		% check if all revisions are known
		lists:foreach(
			fun(RId) -> ets:member(RevTbl, RId) orelse throw(enoent) end,
			RevPath),

		% check if the revisions are all connected to each other
		lists:foreach(
			fun({RId1, RId2}) ->
				[{_, #revision{parents=Parents}}] = ets:lookup(RevTbl, RId2),
				lists:member(RId1, Parents) orelse throw(einval)
			end,
			zip_parent_child(RevPath)),

		% try to update
		[OldRId | Path] = RevPath,
		NewRId = lists:last(Path),
		case ets:lookup(DocTbl, DId) of
			% already pointing to requested rev
			[{_, NewRId, _, _}] ->
				{ok, S};

			% forward old version
			[{_, OldRId, PreRIds, _}] ->
				ets:insert(DocTbl, {DId, NewRId, PreRIds, S#state.gen}),
				hotchpotch_vol_monitor:trigger_mod_doc(S#state.sid, DId),
				{ok, next_gen(S)};

			% errors
			[_] -> throw(econflict);
			[]  -> throw(enoent)
		end
	catch
		throw:Reason -> {{error, Reason}, S}
	end.


% ok | {ok, MissingParts, Handle} | {error, Reason}
do_put_rev(RId, Rev, User, S) ->
	case ets:member(S#state.rev_tbl, RId) of
		false ->
			Parts = Rev#revision.parts,
			PartTbl = S#state.part_tbl,
			case [P || {_, PId} = P <- Parts, not dets:member(PartTbl, PId)] of
				[] ->
					do_put_rev_commit(RId, Rev, S);

				Missing ->
					% Some parts are missing and need to be uploaded. Make sure
					% nothing gets garbage collected in between...
					S2 = lists:foldl(
						fun({_, PId}, AccS) -> do_lock({part, PId}, AccS) end,
						S,
						Parts),
					{ok, Handle} = hotchpotch_file_store_imp:start_link(RId,
						Rev, Missing, User),
					NeededFourCCs = [FCC || {FCC, _} <- Missing],
					{{ok, NeededFourCCs, Handle}, S2}
			end;

		true ->
			{ok, S}
	end.


do_put_rev_commit(RId, Rev, #state{sid=SId, rev_tbl=RevTbl} = S) ->
	ets:insert(RevTbl, {RId, Rev}),
	hotchpotch_vol_monitor:trigger_add_rev(SId, RId),
	{ok, S}.


do_sync_get_changes(PeerSId, Caller, S) ->
	case sync_lock(PeerSId, Caller, S) of
		{ok, S2} ->
			#state{doc_tbl=DocTbl, peer_tbl=PeerTbl} = S2,
			Anchor = case ets:lookup(PeerTbl, PeerSId) of
				[{_, Value}] -> Value;
				[] -> 0
			end,
			Changes = ets:select(DocTbl,
				[{{'$1','_','_','$2'},[{'>','$2',Anchor}],[{{'$1','$2'}}]}]),
			Backlog = lists:sort(
				fun({_Doc1, Seq1}, {_Doc2, Seq2}) -> Seq1 =< Seq2 end,
				Changes),
			{{ok, Backlog}, S2};

		error ->
			{{error, ebusy}, S}
	end.


do_sync_set_anchor(PeerSId, SeqNum, #state{peer_tbl=PeerTbl}) ->
	ets:insert(PeerTbl, {PeerSId, SeqNum}).


do_sync_finish(PeerSId, Caller, #state{synclocks=SLocks} = S) ->
	case dict:find(PeerSId, SLocks) of
		{ok, Caller} ->
			unlink(Caller),
			{ok, S#state{synclocks=dict:erase(PeerSId, SLocks)}};
		{ok, _Other} ->
			{{error, eacces}, S};
		error ->
			{{error, einval}, S}
	end.


do_lock(ObjId, #state{objlocks=ObjLocks} = S) ->
	S#state{objlocks = dict:update_counter(ObjId, 1, ObjLocks)}.


do_unlock(ObjId, #state{objlocks=ObjLocks} = S) ->
	NewObjLocks = case dict:fetch(ObjId, ObjLocks) of
		1     -> dict:erase(ObjId, ObjLocks);
		Depth -> dict:store(ObjId, Depth-1, ObjLocks)
	end,
	S#state{objlocks=NewObjLocks}.


do_gc(S) ->
	save_store(dirty, S),
	GcObj1 = ets:foldl(
		fun({DId, RId, PreRIds, _}, Acc) ->
			dict:store({doc, DId}, [{rev, R} || R <- [RId | PreRIds]], Acc)
		end,
		dict:new(),
		S#state.doc_tbl),
	GcObj2 = ets:foldl(
		fun({RId, Rev}, Acc) ->
			DRefs = [{doc, D} || D <- Rev#revision.doc_links],
			RRefs = [{rev, R} || R <- Rev#revision.parents ++ Rev#revision.rev_links],
			PRefs = [{part, P} || {_, P} <- Rev#revision.parts],
			dict:store({rev, RId}, DRefs++RRefs++PRefs, Acc)
		end,
		GcObj1,
		S#state.rev_tbl),
	AllObj = dets:foldl(
		fun({PId, _}, Acc) ->
			dict:store({part, PId}, [], Acc)
		end,
		GcObj2,
		S#state.part_tbl),
	GreyList = [{doc, S#state.sid} | dict:fetch_keys(S#state.objlocks)],
	DelObj = dict:fetch_keys(gc_step(GreyList, AllObj)),
	{GcDocs, GcRevs, GcParts} = lists:foldl(
		fun
			({doc, _}, {AccD, AccR, AccP}) -> {AccD+1, AccR, AccP};
			({rev, _}, {AccD, AccR, AccP}) -> {AccD, AccR+1, AccP};
			({part, _}, {AccD, AccR, AccP}) -> {AccD, AccR, AccP+1}
		end,
		{0, 0, 0},
		DelObj),
	error_logger:info_report([
		{'store', hotchpotch_util:bin_to_hexstr(S#state.sid)},
		{'type', 'hotchpotch_file_store'},
		{'gc_docs', GcDocs},
		{'gc_revs', GcRevs},
		{'gc_parts', GcParts} ]),
	gc_cleanup(DelObj, S).


do_fsck(_S) ->
	% TODO: implement. But what to do with broken objects? Deleting might
	% be a bad idea.
	%
	% Steps:
	%   * do all revs have their parts?
	%   * do all parts files exist
	%   * are the file hashes correct?
	ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Local helpers...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

sync_trap_exit(From, #state{synclocks=SLocks} = S) ->
	Found = dict:fold(
		fun(_Guid, Pid, Acc) -> Acc or (Pid == From) end,
		false,
		SLocks),
	case Found of
		true ->
			NewLocks = dict:filter(fun(_, Pid) -> Pid =/= From end, SLocks),
			{ok, S#state{synclocks=NewLocks}};
		false ->
			error
	end.


sync_lock(PeerSId, Caller, #state{synclocks=SLocks} = S) ->
	case dict:find(PeerSId, SLocks) of
		{ok, Caller} ->
			{ok, S};
		{ok, _Other} ->
			error;
		error ->
			link(Caller),
			{ok, S#state{synclocks=dict:store(PeerSId, Caller, SLocks)}}
	end.


% lock document and part hashes, then start writer process
start_writer(DId, PreRId, Rev, User, S) ->
	S2 = lists:foldl(
		fun({_, PId}, AccS) -> do_lock({part, PId}, AccS) end,
		S,
		Rev#revision.parts),
	S3 = do_lock({doc, DId}, S2),
	{ok, _} = Reply =
		hotchpotch_file_store_io:start_link(DId, PreRId, Rev, User),
	{Reply, S3}.


part_size(PId, #state{part_tbl=PartTbl}) ->
	case dets:lookup(PartTbl, PId) of
		[{_, Size}] when is_integer(Size) ->
			Size;
		[{_, Data}] when is_binary(Data) ->
			size(Data)
	end.


load_store(Id, #state{path=Path} = S) ->
	IdStr = atom_to_list(Id),
	S2 = case ets:file2tab(Path ++ "/docs.ets") of
		{ok, DocTbl} ->
			S#state{doc_tbl=DocTbl};
		{error,{read_error,{file_error,_,enoent}}} ->
			S#state{doc_tbl=ets:new(list_to_atom(IdStr ++ "_docs"), [])}
	end,
	S3 = case ets:file2tab(Path ++ "/revs.ets") of
		{ok, RevTbl} ->
			S2#state{rev_tbl=RevTbl};
		{error,{read_error,{file_error,_,enoent}}} ->
			S2#state{rev_tbl=ets:new(list_to_atom(IdStr ++ "_revs"), [])}
	end,
	PartTbl = list_to_atom(IdStr ++ "_parts"),
	{ok, _} = dets:open_file(PartTbl, [{file, Path ++ "/parts.dets"}]),
	S4 = S3#state{part_tbl=PartTbl},
	S5 = case ets:file2tab(Path ++ "/peers.ets") of
		{ok, PeerTbl} ->
			S4#state{peer_tbl=PeerTbl};
		{error,{read_error,{file_error,_,enoent}}} ->
			S4#state{peer_tbl=ets:new(list_to_atom(IdStr ++ "_peers"), [])}
	end,
	case file:consult(Path ++ "/info") of
		{ok, Info} ->
			{sid, Sid} = lists:keyfind(sid, 1, Info),
			{gen, Gen} = lists:keyfind(gen, 1, Info),
			S5#state{gen=Gen, gc_gen=Gen, sid=Sid};

		{error, enoent} ->
			S5#state{gen=0, gc_gen=0, sid=crypto:rand_bytes(16)}
	end.


save_store(MountState, #state{path=Path} = S) ->
	ok = dets:sync(S#state.part_tbl),
	ok = ets:tab2file(S#state.doc_tbl, Path ++ "/docs.ets.new"),
	ok = ets:tab2file(S#state.rev_tbl, Path ++ "/revs.ets.new"),
	ok = ets:tab2file(S#state.peer_tbl, Path ++ "/peers.ets.new"),
	{ok, File} = file:open(Path ++ "/info.new", [write]),
	try
		ok = file:write(File, "{version, 1}.\n"),
		ok = file:write(File, io_lib:print({state, MountState})),
		ok = file:write(File, ".\n"),
		ok = file:write(File, io_lib:print({sid, S#state.sid})),
		ok = file:write(File, ".\n"),
		ok = file:write(File, io_lib:print({gen, S#state.gen})),
		ok = file:write(File, ".\n"),
		ok = file:sync(File)
	after
		file:close(File)
	end,
	ok = file:rename(Path ++ "/docs.ets.new", Path ++ "/docs.ets"),
	ok = file:rename(Path ++ "/revs.ets.new", Path ++ "/revs.ets"),
	ok = file:rename(Path ++ "/peers.ets.new", Path ++ "/peers.ets"),
	ok = file:rename(Path ++ "/info.new", Path ++ "/info").


close_store(S) ->
	ets:delete(S#state.doc_tbl),
	ets:delete(S#state.rev_tbl),
	dets:close(S#state.part_tbl),
	ets:delete(S#state.peer_tbl).


check_root_doc(Name, #state{sid=SId, gen=Gen} = S) ->
	case ets:member(S#state.doc_tbl, SId) of
		true ->
			S;
		false ->
			RootContent = dict:new(),
			ContentPId = crd_write_part(RootContent, S),
			Annotation1 = dict:new(),
			Annotation2 = dict:store(<<"title">>, list_to_binary(Name), Annotation1),
			Annotation3 = dict:store(<<"comment">>, list_to_binary("<<Initial store creation>>"), Annotation2),
			Sync = dict:store(<<"sticky">>, true, dict:new()),
			RootMeta1 = dict:new(),
			RootMeta2 = dict:store(<<"org.hotchpotch.annotation">>, Annotation3, RootMeta1),
			RootMeta3 = dict:store(<<"org.hotchpotch.sync">>, Sync, RootMeta2),
			MetaPId = crd_write_part(RootMeta3, S),
			RootRev = #revision{
				parts     = [{<<"HPSD">>, ContentPId}, {<<"META">>, MetaPId}],
				parents   = [],
				mtime     = hotchpotch_util:get_time(),
				type      = <<"org.hotchpotch.store">>,
				creator   = <<"org.hotchpotch.file-store">>,
				doc_links = [],
				rev_links = []
			},
			RId = hotchpotch_store:hash_revision(RootRev),
			ets:insert(S#state.rev_tbl, {RId, RootRev}),
			ets:insert(S#state.doc_tbl, {SId, RId, [], Gen}),
			S#state{gen=Gen+1}
	end.


crd_write_part(Data, S) ->
	BinData = hotchpotch_struct:encode(Data),
	PId = binary_part(crypto:sha(BinData), 0, 16),
	ok = dets:insert(S#state.part_tbl, {PId, BinData}),
	PId.


zip_parent_child([Head | Childs]) ->
	lists:reverse(zip_parent_child(Head, Childs, [])).


zip_parent_child(Parent, [Child], Acc) ->
	[{Parent, Child} | Acc];

zip_parent_child(Parent, [Child | Ancestors], Acc) ->
	zip_parent_child(Child, Ancestors, [{Parent, Child} | Acc]).


gc_step([], WhiteSet) ->
	WhiteSet;

gc_step([ObjId | GreyList], WhiteSet) ->
	NewWhiteSet = dict:erase(ObjId, WhiteSet),
	NewGreyList = case dict:find(ObjId, WhiteSet) of
		{ok, Refs} -> Refs ++ GreyList;
		error -> GreyList
	end,
	gc_step(NewGreyList, NewWhiteSet).


gc_cleanup(DelObj, S) ->
	lists:foreach(
		fun(ObjId) -> gc_cleanup_obj(ObjId, S) end,
		DelObj).


gc_cleanup_obj({doc, DId}, #state{doc_tbl=DocTbl}) ->
	ets:delete(DocTbl, DId);

gc_cleanup_obj({rev, RId}, #state{rev_tbl=RevTbl}) ->
	ets:delete(RevTbl, RId);

gc_cleanup_obj({part, PId}, #state{path=Path, part_tbl=PartTbl}) ->
	case dets:lookup(PartTbl, PId) of
		[{_, Size}] when is_integer(Size) ->
			file:delete(hotchpotch_util:build_path(Path, PId));
		_ ->
			ok
	end,
	dets:delete(PartTbl, PId).


next_gen(#state{gc_tmr=GcTmr, gc_gen=GcGen, gen=Gen} = S) ->
	Updates = Gen-GcGen,
	S2 = if
		Updates >= ?GC_MAX_UPDATES ->
			case erlang:cancel_timer(GcTmr) of
				Remain when is_integer(Remain) ->
					erlang:start_timer(0, self(), gc);
				false ->
					ok % already expired, message should be in queue
			end,
			S#state{gc_gen=Gen}; % prevent multiple schedules

		Updates > ?GC_MIN_UPDATES ->
			case erlang:cancel_timer(GcTmr) of
				Remain when is_integer(Remain) ->
					Timer = erlang:start_timer(?GC_SLACK_TIME, self(), gc),
					S#state{gc_tmr=Timer};
				false ->
					S % already expired, message should be in queue
			end;

		Updates == ?GC_MIN_UPDATES ->
			Timer = erlang:start_timer(?GC_SLACK_TIME, self(), gc),
			S#state{gc_tmr=Timer};

		true ->
			S
	end,
	S2#state{gen=Gen+1}.
