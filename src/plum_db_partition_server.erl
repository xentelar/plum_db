%% -----------------------------------------------------------------------------
%%    Copyright 2018 Ngineo Limited t/a Leapsight
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.
%% -----------------------------------------------------------------------------

%% -----------------------------------------------------------------------------
%% @doc  A wrapper for an elevelb instance.
%% @end
%% -----------------------------------------------------------------------------
-module(plum_db_partition_server).
-behaviour(gen_server).
-include("plum_db.hrl").


%% leveldb uses $\0 but since external term format will contain nulls
%% we need an additional separator. We use the ASCII unit separator
%% ($\31) that was design to separate fields of a record.
%% -define(KEY_SEPARATOR, <<0, $\31, 0>>).

-record(state, {
    name                                ::  atom(),
    partition                           ::  non_neg_integer(),
    db_ref 								::	eleveldb:db_ref() | undefined,
    ram_tab                             ::  atom(),
    ram_disk_tab                        ::  atom(),
	config = []							::	opts(),
	data_root							::	file:filename(),
	open_opts = []						::	opts(),
	read_opts = []						::	opts(),
    write_opts = []						::	opts(),
    fold_opts = [{fill_cache, false}]	::	opts(),
    iterators = []                      ::  iterators()
}).

-record(partition_iterator, {
    owner_ref               ::  reference(),
    partition               ::  non_neg_integer(),
    full_prefix             ::  plum_db_prefix(),
    keys_only = false       ::  boolean(),
    last_key                ::  plum_db_pkey() | undefined,
    disk_done = true        ::  boolean(),
    disk                    ::  eleveldb:itr_ref() | undefined,
    ram_done = true         ::  boolean(),
    ram_tab                 ::  atom(),
    ram                     ::  key | {cont, any()} | undefined,
    ram_disk_done = true    ::  boolean(),
    ram_disk_tab            ::  atom(),
    ram_disk                ::  key | {cont, any()} | undefined
}).

-type opts()                :: 	[{atom(), term()}].
-type iterator()            ::  #partition_iterator{}.
-type iterators()           ::  [iterator()].
-type iterator_action()     ::  first
                                | last | next | prev
                                | prefetch | prefetch_stop
                                | binary().

-export_type([iterator/0]).

-export([byte_size/1]).
-export([delete/1]).
-export([delete/2]).
-export([get/1]).
-export([get/2]).
-export([is_empty/1]).
-export([iterator/2]).
-export([iterator_close/2]).
-export([iterator_move/2]).
-export([key_iterator/2]).
-export([name/1]).
-export([put/2]).
-export([put/3]).
-export([start_link/2]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_link(Partition :: non_neg_integer(), Opts :: opts()) -> any().

start_link(Partition, Opts) ->
    Name = name(Partition),
    gen_server:start_link({local, Name}, ?MODULE, [Name, Partition, Opts], []).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
%% @private
name(Partition) ->
    N = valid_partition(Partition),
    list_to_atom(
        "plum_db_partition_" ++ integer_to_list(N) ++ "_server").


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
get(Key) ->
    get(name(plum_db:get_partition(Key)), Key).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
get(Partition, PKey) when is_integer(Partition) ->
    get(name(Partition), PKey);

get(Name, {{Prefix, _}, _} = PKey) when is_atom(Name) ->
    case plum_db:prefix_type(Prefix) of
        undefined ->
            gen_server:call(Name, {get, PKey}, infinity);
        disk ->
            gen_server:call(Name, {get, PKey}, infinity);
        Type when (Type == ram) orelse (Type == ram_disk) ->
            %% TODO during init we would be restoring async the ram_disk
            %% prefixes, so we need to fallback to disk until the restore is
            %% done. The problem is that this forces us to try..catch and fall
            %% back to disk which ads 13 microsecs or check fot the table
            %% existance which is faster (2 microsecs)
            case ets:lookup(table_name(Name, Type), PKey) of
                [] ->
                    {error, not_found};
                [{_, Obj}] ->
                    {ok, Obj}
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
put(PKey, Value) ->
    put(name(plum_db:get_partition(PKey)), PKey, Value).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
put(Partition, PKey, Value) when is_integer(Partition) ->
    put(name(Partition), PKey, Value);

put(Name, {{Prefix, _}, _} = PKey, Value) when is_atom(Name) ->
    case plum_db:prefix_type(Prefix) of
        ram ->
            true = ets:insert(table_name(Name, ram), {PKey, Value}),
            ok;
        _ ->
            gen_server:call(Name, {put, PKey, Value}, infinity)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
delete(Key) ->
    delete(name(plum_db:get_partition(Key)), Key).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
delete(Partition, Key) when is_integer(Partition) ->
    delete(name(Partition), Key);

delete(Name, {{Prefix, _}, _} = PKey) when is_atom(Name) ->
    case plum_db:prefix_type(Prefix) of
        ram ->
            true = ets:delete(table_name(Name, ram), PKey),
            ok;
        _ ->
            gen_server:call(Name, {delete, PKey}, infinity)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
is_empty(Id) when is_integer(Id) ->
    is_empty(name(Id));

is_empty(Store) when is_pid(Store); is_atom(Store) ->
    gen_server:call(Store, is_empty, infinity).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
byte_size(Id) when is_integer(Id) ->
    ?MODULE:byte_size(name(Id));

byte_size(Store) when is_pid(Store); is_atom(Store) ->
    gen_server:call(Store, byte_size, infinity).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
iterator(Id, FullPrefix) when is_integer(Id) ->
    iterator(name(Id), FullPrefix);


iterator(Name, FullPrefix) when is_atom(Name) ->
    Cmd = {iterator, self(), FullPrefix, false},
    Iter = gen_server:call(Name, Cmd, infinity),
    true = maybe_safe_fixtables(Iter, true),
    Iter.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
key_iterator(Id, FullPrefix) when is_integer(Id) ->
    key_iterator(name(Id), FullPrefix);

key_iterator(Name, FullPrefix) when is_atom(Name) ->
    Cmd = {iterator, self(), FullPrefix, true},
    Iter = gen_server:call(Name, Cmd, infinity),
    true = maybe_safe_fixtables(Iter, true),
    Iter.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
iterator_close(Id, Iter) when is_integer(Id) ->
    iterator_close(name(Id), Iter);

iterator_close(Store, #partition_iterator{} = Iter)when is_atom(Store) ->
    Res = gen_server:call(Store, {iterator_close, Iter}, infinity),
    true = maybe_safe_fixtables(Iter, false),
    Res.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec iterator_move(iterator(), iterator_action()) ->
    {ok, Key :: binary(), Value :: binary(), iterator()}
    | {ok, Key :: binary(), iterator()}
    | {error, invalid_iterator}
    | {error, iterator_closed}.

iterator_move(
    #partition_iterator{disk_done = true} = Iter, {undefined, undefined}) ->
    %% We continue with ets so we translate the action
    iterator_move(Iter, first);

iterator_move(#partition_iterator{disk_done = true} = Iter, prefetch) ->
    %% We continue with ets so we translate the action
    iterator_move(Iter, next);

iterator_move(#partition_iterator{disk_done = true} = Iter, prefetch_stop) ->
    %% We continue with ets so we translate the action
    iterator_move(Iter, next);

iterator_move(#partition_iterator{disk_done = false} = Iter, Action) ->

    DbIter = Iter#partition_iterator.disk,

    case eleveldb:iterator_move(DbIter, eleveldb_action(Action)) of
        {ok, Key} ->
            NewIter = Iter#partition_iterator{last_key = Key},
            {ok, decode_key(Key), NewIter};
        {ok, Key, Value} ->
            NewIter = Iter#partition_iterator{last_key = Key},
            {ok, decode_key(Key), binary_to_term(Value), NewIter};
        {error, _} = Error ->
            %% No more data in eleveldb, maybe we continue with ets
            case next_iterator(disk, Iter) of
                undefined ->
                    Error;
                NewIter ->
                    %% We continue in ets so we need to reposition the iterator
                    %% to the first key of the full_prefix
                    iterator_move(NewIter, Iter#partition_iterator.full_prefix)
            end
    end;

iterator_move(#partition_iterator{ram_disk_done = false} = Iter, Action) ->
    iterator_move(ram_disk, Iter#partition_iterator.ram_disk, Iter, Action);

iterator_move(#partition_iterator{ram_done = false} = Iter, Action) ->
    iterator_move(ram, Iter#partition_iterator.ram, Iter, Action);

iterator_move(
    #partition_iterator{
        disk_done = true, ram_done = true, ram_disk_done = true
    }, _) ->
    {error, invalid_iterator}.


%% @private
iterator_move(Type, _, Iter, first) ->
    KeysOnly = Iter#partition_iterator.keys_only,
    Tab = table_name(Iter, Type),

    case ets:first(Tab) of
        '$end_of_table' ->
            {error, invalid_iterator};
        K when KeysOnly ->
            NewIter = update_iterator(Type, Iter, K, key),
            {ok, K, NewIter};
        K ->
            [{K, V}] = ets:lookup(Tab, K),
            NewIter = update_iterator(Type, Iter, K, key),
            {ok, K, V, NewIter}
    end;

iterator_move(Type, key, Iter, next) ->
    KeysOnly = Iter#partition_iterator.keys_only,
    Tab = table_name(Iter, Type),

    case ets:next(Tab, Iter#partition_iterator.last_key) of
        '$end_of_table' ->
            {error, invalid_iterator};
        K when KeysOnly ->
            NewIter = update_iterator(ram_disk, Iter, K, key),
            {ok, K, NewIter};
        K ->
            [{K, V}] = ets:lookup(Tab, K),
            NewIter = update_iterator(ram_disk, Iter, K, key),
            {ok, K, V, NewIter}
    end;

iterator_move(Type, {cont, Cont0}, Iter, next) ->
    case ets:select(Cont0) of
        '$end_of_table' ->
            case next_iterator(Type, Iter) of
                undefined ->
                    {error, invalid_iterator};
                NewIter ->
                    %% We continue in ets so we need to reposition the iterator
                    %% to the first key of the full_prefix
                    iterator_move(NewIter, Iter#partition_iterator.full_prefix)
            end;
        {[{K, V}], Cont1} ->
            NewIter = update_iterator(Type, Iter, K, {cont, Cont1}),
            {ok, K, V, NewIter};
        {[K], Cont1} ->
            NewIter = update_iterator(Type, Iter, K, {cont, Cont1}),
            {ok, K, NewIter}
    end;

iterator_move(Type, key, Iter, prev) ->
    KeysOnly = Iter#partition_iterator.keys_only,
    Tab = table_name(Iter, Type),

    case ets:prev(Tab, Iter#partition_iterator.last_key) of
        '$end_of_table' ->
            %% No more data in ets, maybe we continue with eleveldb
            case prev_iterator(Type, Iter) of
                undefined ->
                    {error, invalid_iterator};
                NewIter ->
                    iterator_move(NewIter, prev)
            end;
        K when KeysOnly ->
            NewIter = update_iterator(Type, Iter, K, key),
            {ok, K, NewIter};
        K ->
            [{K, V}] = ets:lookup(Tab, K),
            NewIter = update_iterator(Type, Iter, K, key),
            {ok, K, V, NewIter}
    end;

iterator_move(Type, {cont, _}, Iter, prev) ->
    %% We were using ets:select/1, to go backwards we need to switch to
    %% key iteration
    K = Iter#partition_iterator.last_key,
    NewIter = update_iterator(Type, Iter, K, key),
    iterator_move(NewIter, prev);


iterator_move(Type, _, Iter, FullPrefix) ->
    Tab = table_name(Iter, Type),
    MatchSpec = ets_match_spec(FullPrefix, Iter#partition_iterator.keys_only),

    case ets:select(Tab, MatchSpec, 1) of
        '$end_of_table' ->
            {error, invalid_iterator};
        {[{K, V}], Cont1} ->
            NewIter = update_iterator(Type, Iter, K, {cont, Cont1}),
            {ok, K, V, NewIter};
        {[K], Cont1} ->
            NewIter = update_iterator(Type, Iter, K, {cont, Cont1}),
            {ok, K, NewIter}
    end.






%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



init([Name, Partition, Opts]) ->
    %% Initialize random seed
    rand:seed(exsplus, erlang:timestamp()),

    process_flag(trap_exit, true),

    DataRoot = filename:join([
        app_helper:get_prop_or_env(data_dir, Opts, plum_db),
        "db",
        integer_to_list(Partition)
    ]),

	case filelib:ensure_dir(DataRoot) of
        ok ->
            State0 = init_state(Name, Partition, DataRoot, Opts),
            case open_db(State0) of
                {ok, State1} ->
                    init_from_db(State1);
                {error, Reason} ->
                    {stop, Reason}
            end;
		{error, Reason} ->
		 	{stop, Reason}
    end.


handle_call({get, PKey}, _From, State) ->
    DbRef = State#state.db_ref,
    Opts = State#state.read_opts,
    Result = result(eleveldb:get(DbRef, encode_key(PKey), Opts)),
    {reply, Result, State};

handle_call({put, PKey, Value}, _From, State) ->
    DbRef = State#state.db_ref,
    Opts = State#state.write_opts,
    {{Prefix, _}, _} = PKey,
    Result = case plum_db:prefix_type(Prefix) of
        ram ->
            true = ets:insert(State#state.ram_tab, {PKey, Value}),
            ok;
        ram_disk ->
            true = ets:insert(State#state.ram_disk_tab, {PKey, Value}),
            Actions = [{put, encode_key(PKey), term_to_binary(Value)}],
            result(eleveldb:write(DbRef, Actions, Opts));
        _ ->
            Actions = [{put, encode_key(PKey), term_to_binary(Value)}],
            result(eleveldb:write(DbRef, Actions, Opts))
    end,
    {reply, Result, State};

handle_call({delete, PKey}, _From, State) ->
    DbRef = State#state.db_ref,
    Opts = State#state.write_opts,
    {{Prefix, _}, _} = PKey,
    Result = case plum_db:prefix_type(Prefix) of
        ram ->
            true = ets:delete(State#state.ram_tab, PKey),
            ok;
        ram_disk ->
            true = ets:delete(State#state.ram_disk_tab, PKey),
            Actions = [{delete, encode_key(PKey)}],
            result(eleveldb:write(DbRef, Actions, Opts));
        _ ->
            Actions = [{delete, encode_key(PKey)}],
            result(eleveldb:write(DbRef, Actions, Opts))
    end,
    {reply, Result, State};

handle_call(byte_size, _From, State) ->
    DbRef = State#state.db_ref,
    Ram = ets:info(State#state.ram_tab, memory),
    RamDisk = ets:info(State#state.ram_disk_tab, memory),
    Ets = (Ram + RamDisk) * erlang:system_info(wordsize),

    try eleveldb:status(DbRef, <<"leveldb.total-bytes">>) of
        {ok, Bin} ->
            {reply, binary_to_integer(Bin) + Ets, State}
    catch
        error:_ ->
            {reply, Ets, State}
    end;

handle_call(is_empty, _From, State) ->
    DbRef = State#state.db_ref,
    Ram = ets:info(State#state.ram_tab, size),
    RamDisk = ets:info(State#state.ram_disk_tab, size),
    Result = eleveldb:is_empty(DbRef) andalso (Ram + RamDisk) == 0,
    {reply, Result, State};

handle_call({iterator, Pid, FullPrefix, KeysOnly}, _From, State) ->
    Ref = erlang:monitor(process, Pid),
    {Prefix, _} = FullPrefix,

    PartIter0 = #partition_iterator{
        partition = State#state.partition,
        owner_ref = Ref,
        full_prefix = FullPrefix,
        keys_only = KeysOnly
    },

    PartIter1 = case Prefix == undefined of
        true ->
            %% We iterate over ram and disk only since everything in ram_disk
            %% is in disk (but not everything in disk is in ram_disk)
            set_ram_iterator(set_disk_iterator(PartIter0, State), State);
        false ->
            case plum_db:prefix_type(Prefix) of
                ram ->
                    set_ram_iterator(PartIter0, State);
                ram_disk ->
                    set_ram_disk_iterator(PartIter0, State);
                Type when Type == disk orelse Type == undefined ->
                    %% If prefix is undefined then data is on disk by default
                    set_disk_iterator(PartIter0, State)
            end
    end,
    {reply, PartIter1, add_iterator(PartIter1, State)};

handle_call({iterator_close, Iter}, _From, State0) ->
    State1 = close_iterator(Iter, State0),
    {reply, ok, State1}.


handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info({'DOWN', Ref, process, _, _}, State0) ->
    State1 = close_iterator(Ref, State0),
    {noreply, State1};

handle_info(_Info, State) ->
    {noreply, State}.


terminate(_Reason, State) ->
    %% Close iterators
    Fun = fun(Iter, Acc) ->
        close_iterator(Iter, Acc)
    end,
    _ = lists:foldl(Fun, State, State#state.iterators),
    %% Close eleveldb
    catch eleveldb:close(State#state.db_ref),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE: ELEVELDB INIT
%% Borrowed from riak_kv_eleveldb_backend.erl
%% =============================================================================


%% @private
init_state(Name, Partition, DataRoot, Config) ->
    %% Merge the proplist passed in from Config with any values specified by the
    %% eleveldb app level; precedence is given to the Config.
    MergedConfig = orddict:merge(
        fun(_K, VLocal, _VGlobal) -> VLocal end,
        orddict:from_list(Config), % Local
        orddict:from_list(application:get_all_env(eleveldb))), % Global

    %% Use a variable write buffer size in order to reduce the number
    %% of vnodes that try to kick off compaction at the same time
    %% under heavy uniform load...
    WriteBufferMin = config_value(
        write_buffer_size_min, MergedConfig, 30 * 1024 * 1024),
    WriteBufferMax = config_value(
        write_buffer_size_max, MergedConfig, 60 * 1024 * 1024),
    WriteBufferSize = WriteBufferMin + rand:uniform(
        1 + WriteBufferMax - WriteBufferMin),

    %% Update the write buffer size in the merged config and make sure
    %% create_if_missing is set to true
    FinalConfig = orddict:store(
        write_buffer_size,
        WriteBufferSize,
        orddict:store(create_if_missing, true, MergedConfig)),

    %% Parse out the open/read/write options
    {OpenOpts, _BadOpenOpts} = eleveldb:validate_options(open, FinalConfig),
    {ReadOpts, _BadReadOpts} = eleveldb:validate_options(read, FinalConfig),
    {WriteOpts, _BadWriteOpts} = eleveldb:validate_options(write, FinalConfig),

    %% Use read options for folding, but FORCE fill_cache to false
    FoldOpts = lists:keystore(fill_cache, 1, ReadOpts, {fill_cache, false}),

    %% Warn if block_size is set
    SSTBS = proplists:get_value(sst_block_size, OpenOpts, false),
    BS = proplists:get_value(block_size, OpenOpts, false),

    case BS /= false andalso SSTBS == false of
        true ->
            lager:warning(
                "eleveldb block_size has been renamed sst_block_size "
                "and the current setting of ~p is being ignored.  "
                "Changing sst_block_size is strongly cautioned "
                "against unless you know what you are doing.  Remove "
                "block_size from app.config to get rid of this "
                "message.\n", [BS]);
        _ ->
            ok
    end,

    %% We create two ets tables for ram and ram_disk storage levels
    EtsOpts = [
        named_table, public,
        {read_concurrency, true}, {write_concurrency, true}
    ],

    %% TODO Ram Table should be protected by a table manager to avoid losing
    %% data

    RamTab = table_name(Partition, ram),
    RamTab = ets:new(RamTab, EtsOpts),

    %% TODO RamDisk Table should be restore on startup asynchronously and
    %% during its restore all gets should go to disk, so we should not set
    %% the table name here but later when the restore is finished
    RamDiskTab = table_name(Partition, ram_disk),
    RamDiskTab = ets:new(RamDiskTab, EtsOpts),

    #state {
        name = Name,
        partition = Partition,
        ram_tab = RamTab,
        ram_disk_tab = RamDiskTab,
		config = FinalConfig,
        data_root = DataRoot,
		open_opts = OpenOpts,
		read_opts = ReadOpts,
		write_opts = WriteOpts,
		fold_opts = FoldOpts
	}.


%% @private
config_value(Key, Config, Default) ->
    case orddict:find(Key, Config) of
        error ->
            Default;
        {ok, Value} ->
            Value
    end.


%% @private
open_db(State0) ->
    RetriesLeft = app_helper:get_env(plum_db, store_open_retry_Limit, 30),
    open_db(State0, max(1, RetriesLeft), undefined).


%% @private
open_db(_State0, 0, LastError) ->
    {error, LastError};

open_db(State0, RetriesLeft, _) ->
    case eleveldb:open(State0#state.data_root, State0#state.open_opts) of
        {ok, Ref} ->
            {ok, State0#state{db_ref = Ref}};
        %% Check specifically for lock error, this can be caused if
        %% a crashed vnode takes some time to flush leveldb information
        %% out to disk.  The process is gone, but the NIF resource cleanup
        %% may not have completed.
    	{error, {db_open, OpenErr} = Reason} ->
            case lists:prefix("IO error: lock ", OpenErr) of
                true ->
                    SleepFor = app_helper:get_env(
                        plum_db, store_open_retries_delay, 2000),
                    lager:debug("Leveldb backend retrying ~p in ~p ms after error ~s\n",
                                [State0#state.data_root, SleepFor, OpenErr]),
                    timer:sleep(SleepFor),
                    open_db(State0, RetriesLeft - 1, Reason);
                false ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.




%% =============================================================================
%% PRIVATE: ETS INIT
%% Borrowed from riak_kv_eleveldb_backend.erl
%% =============================================================================

%% @private
init_from_db(State) ->
    _ = lager:info(
        "Initialising partition ~p",
        [State#state.partition]
    ),
    %% We create the in-memory db copy for ram and ram_disk prefixes
    Tab = State#state.ram_disk_tab,

    %% TODO do this in a separate process asynchronously
    %% We load ram_disk prefixes from disk to ram
    PrefixList = maps:to_list(plum_db:prefixes()),
    {ok, DbIter} = eleveldb:iterator(State#state.db_ref, State#state.fold_opts),


    try
        Fun = fun
            ({Prefix, ram_disk}, ok) ->
                _ = lager:info(
                    "Loading data from prefix ~p to ram",
                    [Prefix]
                ),
                First = sext:prefix({{Prefix, '_'}, '_'}),
                Next = eleveldb:iterator_move(DbIter, First),
                init_prefix_iterate(
                    Next, DbIter, First, erlang:byte_size(First), Tab);
            (_, ok) ->
                ok
        end,
        ok = lists:foldl(Fun, ok, PrefixList),
        {ok, State}
    catch
        ?EXCEPTION(Class, Reason, Stacktrace) ->
            _ = lager:error(
                "Error initialisation of partition; partition=~p, class=~p, reason=~p, stacktrace=~p",
                [State#state.partition, Class, Reason, ?STACKTRACE(Stacktrace)]
            )
    after
        _ = lager:info(
            "Finished initialisation of partition ~p",
            [State#state.partition]
        ),
        eleveldb:iterator_close(DbIter)
    end.


%% @private
init_prefix_iterate({error, _}, _, _, _, _) ->
    %% We have no more matches in this Prefix
    ok;

init_prefix_iterate({ok, K, V}, DbIter, BinPrefix, BPSize, Tab) ->
    case K of
        <<BinPrefix:BPSize/binary, _/binary>> ->
            %% Element is {{P, K}, MetadataObj}
            PKey = decode_key(K),
            true = ets:insert(Tab, {PKey, binary_to_term(V)}),
            Next = eleveldb:iterator_move(DbIter, prefetch),
            init_prefix_iterate(Next, DbIter, BinPrefix, BPSize, Tab);
        _ ->
            %% We have no more matches in this Prefix
            ok
    end.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
table_name(#partition_iterator{} = Iter, ram) ->
    Iter#partition_iterator.ram_tab;

table_name(#partition_iterator{} = Iter, ram_disk) ->
    Iter#partition_iterator.ram_disk_tab;

table_name(Name, ram) when is_atom(Name) ->
    list_to_existing_atom(atom_to_list(Name) ++ "_ram");

table_name(Name, ram_disk) when is_atom(Name) ->
    list_to_existing_atom(atom_to_list(Name) ++ "_ram_disk");

table_name(N, ram) when is_integer(N) ->
    list_to_atom(
        "plum_db_partition_" ++ integer_to_list(N) ++ "_server_ram");

table_name(N, ram_disk) when is_integer(N) ->
    list_to_atom(
        "plum_db_partition_" ++ integer_to_list(N) ++ "_server_ram_disk").





%% @private
next_iterator(disk, #partition_iterator{ram_disk_tab = undefined} = Iter) ->
    next_iterator(ram_disk, Iter);

next_iterator(disk, Iter) ->
    Iter#partition_iterator{
        disk_done = true,
        ram_disk_done = false
    };

next_iterator(ram_disk, #partition_iterator{ram_tab = undefined}) ->
    undefined;

next_iterator(ram_disk, Iter) ->
    Iter#partition_iterator{
        disk_done = true,
        ram_disk_done = true,
        ram_done = false
    };

next_iterator(ram, _) ->
    undefined.


%% @private
prev_iterator(ram, #partition_iterator{ram_disk_tab = undefined} = Iter) ->
    prev_iterator(ram_disk, Iter);
prev_iterator(ram, Iter) ->
    Iter#partition_iterator{
        ram_disk = false,
        ram_done = false
    };
prev_iterator(ram_disk, #partition_iterator{disk = undefined}) ->
    undefined;
prev_iterator(ram_disk, Iter) ->
    Iter#partition_iterator{
        disk_done = false,
        ram_disk_done = false
    };
prev_iterator(disk, _) ->
    undefined.

%% @private
eleveldb_action({undefined, undefined}) -> first;
eleveldb_action({Prefix, undefined}) -> sext:prefix({{Prefix, '_'}, '_'});
eleveldb_action({_, _} = FullPrefix) -> sext:prefix({FullPrefix, '_'});
eleveldb_action(Action) -> Action.


%% @private
ets_match_spec({Prefix, undefined}, true) ->
    [{{{{Prefix, '$1'}, '_'}, '_'}, [], [{{Prefix, '$1'}}]}];

ets_match_spec({Prefix, undefined}, false) ->
    [{{{{Prefix, '_'}, '_'}, '_'}, [], ['$_']}];

ets_match_spec(FullPrefix, true) ->
    [{{{FullPrefix, '_'}, '_'}, [], [{{FullPrefix, '_'}}]}];

ets_match_spec(FullPrefix, false) ->
    [{{{FullPrefix, '_'}, '_'}, [], ['$_']}].



%% -----------------------------------------------------------------------------
%% @private
%% @doc Validates the id is within range, returning the Id if it is or failing
%% with invalid_store_id otherwise.
%% @end
%% -----------------------------------------------------------------------------
valid_partition(Id) ->
   plum_db:is_partition(Id) orelse error(invalid_store_id),
   Id.



%% @private
set_disk_iterator(#partition_iterator{} = PartIter0, State) ->
    DbRef = State#state.db_ref,
    Opts = State#state.fold_opts,
    KeysOnly = PartIter0#partition_iterator.keys_only,

    {ok, DbIter} = case KeysOnly of
        true ->
            eleveldb:iterator(DbRef, Opts, keys_only);
        false ->
            eleveldb:iterator(DbRef, Opts)
    end,

    PartIter0#partition_iterator{
        disk_done = false,
        disk = DbIter
    }.


%% @private
set_ram_iterator(#partition_iterator{} = PartIter0, State) ->
    PartIter0#partition_iterator{
        ram_tab = State#state.ram_tab,
        ram_done = false,
        ram = undefined
    }.


%% @private
set_ram_disk_iterator(#partition_iterator{} = PartIter0, State) ->
    PartIter0#partition_iterator{
        ram_disk_tab = State#state.ram_disk_tab,
        ram_disk_done = false,
        ram_disk = undefined
    }.


%% @private
update_iterator(ram, Iter, Key, Cont) ->
    Iter#partition_iterator{last_key = Key, ram = Cont};

update_iterator(ram_disk, Iter, Key, Cont) ->
    Iter#partition_iterator{last_key = Key, ram_disk = Cont}.



%% @private
add_iterator(#partition_iterator{owner_ref = OwnerRef} = Iter, State)
when is_reference(OwnerRef) ->
    Iterators1 = lists:keystore(OwnerRef, 2, State#state.iterators, Iter),
    State#state{iterators = Iterators1}.


%% @private
take_iterator(#partition_iterator{owner_ref = OwnerRef}, State) ->
    Pos = #partition_iterator.owner_ref,
    case lists:keytake(OwnerRef, Pos, State#state.iterators) of
        {value, Iter, Iterators1} ->
            {Iter, State#state{iterators = Iterators1}};
        false ->
            error
    end.


%% @private
close_iterator(Iter, State0) ->
    case take_iterator(Iter, State0) of
        {#partition_iterator{disk = undefined}, State1} ->
            _ = erlang:demonitor(Iter#partition_iterator.owner_ref, [flush]),
            State1;
        {#partition_iterator{disk = DbIter}, State1} ->
            _ = erlang:demonitor(Iter#partition_iterator.owner_ref, [flush]),
            _ = eleveldb:iterator_close(DbIter),
            State1;
        error ->
            State0
    end.


%% @private
maybe_safe_fixtables(Iter, Flag) ->
    true = maybe_safe_fixtable(Iter#partition_iterator.ram_tab, Flag),
    maybe_safe_fixtable(Iter#partition_iterator.ram_disk_tab, Flag).


%% @private
maybe_safe_fixtable(undefined, _) ->
    true;
maybe_safe_fixtable(Tab, Flag) ->
    ets:safe_fixtable(Tab, Flag).


%% @private
result(ok) ->
    ok;

result({ok, Value}) ->
    {ok, binary_to_term(Value)};

result(not_found) ->
    {error, not_found};

result({error, _} = Error) ->
    Error.


%% @private
encode_key(Key) ->
    sext:encode(Key).


%% @private
decode_key(Bin) ->
    sext:decode(Bin).


%% encode_key({}) ->
%% 	E = <<>>,
%% 	<<
%% 		Idx/binary, ?KEY_SEPARATOR/binary,
%% 		TenId/binary, ?KEY_SEPARATOR/binary,
%% 		(encode_element(G))/binary, ?KEY_SEPARATOR/binary,
%% 		E/binary, ?KEY_SEPARATOR/binary,
%% 		E/binary, ?KEY_SEPARATOR/binary,
%% 		E/binary, ?KEY_SEPARATOR/binary,
%% 		(encode_element(Txid))/binary
%% 	>>;

%% encode_key(Term) ->
%%     term_to_binary(Bin);


%% %% @private
%% decode_key(Bin) when is_binary(Bin) ->
%% 	decode_key(binary:split(Bin, ?KEY_SEPARATOR, [global]));

%% decode_key([Term]) ->
%%     binary_to_term(Term);

%% decode_key(_L) when is_list(L) ->
%%     error(not_implemented).


