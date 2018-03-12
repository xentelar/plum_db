%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(pdb).
-behaviour(gen_server).
-behaviour(plumtree_broadcast_handler).
-include("pdb.hrl").

-define(TOMBSTONE, '$deleted').

-record(state, {
    %% an ets table to hold iterators opened
    %% by other nodes
    iterators  :: ets:tab()
}).

-record(iterator, {
    base_iterator           ::  base_iterator(),
    opts                    ::  it_opts()
}).

-record(base_iterator, {
    prefix                  ::  pdb_prefix() | undefined,
    match                   ::  term() | undefined,
    keys_only = false       ::  boolean(),
    obj                     ::  {pdb_key(), pdb_object()}
                                | pdb_key()
                                | undefined,
    ref                     ::  pdb_store_server:iterator(),
    partitions              ::  [non_neg_integer()]
}).

-record(remote_base_iterator, {
    node   :: node(),
    ref    :: reference(),
    prefix :: pdb_prefix() | atom() | binary()
}).

-type state()               ::  #state{}.
-type remote_base_iterator()     ::  #remote_base_iterator{}.
-opaque base_iterator()      ::  #base_iterator{}.



%% Get Option Types
-type value_or_values()     ::  [pdb_value() | pdb_tombstone()]
                                | pdb_value() | pdb_tombstone().
-type fold_fun()            ::  fun(
                                ({pdb_key(), value_or_values()}, any()) ->
                                    any()
                                ).
-type get_opt_default_val() ::  {default, pdb_value()}.
-type get_opt_resolver()    ::  {resolver, pdb_resolver()}.
-type get_opt_allow_put()   ::  {allow_put, boolean()}.
-type get_opt()             ::  get_opt_default_val()
                                | get_opt_resolver() | get_opt_allow_put().
-type get_opts()            ::  [get_opt()].

%% Iterator Types
-type it_opt_resolver()     ::  {resolver, pdb_resolver() | lww}.
-type it_opt_default_fun()  ::  fun((pdb_key()) -> pdb_value()).
-type it_opt_default()      ::  {default, pdb_value() | it_opt_default_fun()}.
-type it_opt_keymatch()     ::  {match, term()}.
-type it_opt()              ::  it_opt_resolver()
                                | it_opt_default()
                                | it_opt_keymatch().
-type it_opts()             ::  [it_opt()].
-type fold_opts()           ::  it_opts().
-type iterator()            ::  #iterator{}.
-type partition()           ::  non_neg_integer().

%% Put Option Types
-type put_opts()            :: [].

%% Delete Option types
-type delete_opts()         :: [].


-export_type([partition/0]).
-export_type([base_iterator/0]).
-export_type([iterator/0]).

-export([decode_key/1]).
-export([delete/2]).
-export([delete/3]).
-export([fold/3]).
-export([fold/4]).
-export([get/2]).
-export([get/3]).
-export([get_object/1]).
-export([get_object/2]).
-export([iterator/1]).
-export([iterator/2]).
-export([iterator_close/1]).
-export([iterator_default/1]).
-export([iterator_done/1]).
-export([iterator_key/1]).
-export([iterator_key_values/1]).
-export([iterate/1]).
-export([iterator_value/1]).
-export([iterator_values/1]).
-export([base_iterator/0]).
-export([base_iterator/1]).
-export([base_iterator/2]).
-export([base_iterator/3]).
-export([base_iterator_prefix/1]).
-export([remote_base_iterator/1]).
-export([remote_base_iterator/2]).
-export([prefix_hash/1]).
-export([put/3]).
-export([put/4]).
-export([to_list/1]).
-export([to_list/2]).
-export([get_partition/1]).
-export([partitions/0]).
-export([partition_count/0]).
-export([is_partition/1]).
-export([merge/3]).


-export([start_link/0]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% plumtree_broadcast_handler callbacks
-export([broadcast_data/1]).
-export([exchange/1]).
-export([graft/1]).
-export([is_stale/1]).
-export([merge/2]).






%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc Start plumtree_metadadata_manager and link to calling process.
%% @end
%% -----------------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @private
%% @doc Returns the server identifier assigned to the FullPrefix of the PKey
%% @end
%% -----------------------------------------------------------------------------
-spec get_partition(term()) -> non_neg_integer().

get_partition(PKey) ->
    erlang:phash2(PKey, partition_count()).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec partitions() -> [non_neg_integer()].

partitions() ->
    [X || X <- lists:seq(0, partition_count())].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec partition_count() -> non_neg_integer().

partition_count() ->
    application:get_env(pdb, partitions, 8).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_partition(non_neg_integer()) -> boolean().

is_partition(Id) ->
    Id >= 0 andalso Id =< partition_count().



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
decode_key(Bin) ->
    sext:decode(Bin).


%% -----------------------------------------------------------------------------
%% @doc Same as get(FullPrefix, Key, [])
%% @end
%% -----------------------------------------------------------------------------
-spec get(pdb_prefix(), pdb_key()) -> pdb_value() | undefined.

get(FullPrefix, Key) ->
    get(FullPrefix, Key, []).


%% -----------------------------------------------------------------------------
%% @doc Retrieves the local value stored at the given prefix and key.
%%
%% get/3 can take the following options:
%%
%% * default: value to return if no value is found, `undefined' if not given.
%% * resolver:  A function that resolves conflicts if they are encountered. If
%% not given last-write-wins is used to resolve the conflicts
%% * allow_put: whether or not to write and broadcast a resolved value.
%% defaults to `true'.
%%
%% NOTE: an update will be broadcast if conflicts are resolved and
%% `allow_put' is `true'. any further conflicts generated by
%% concurrenct writes during resolution are not resolved
%% @end
%% -----------------------------------------------------------------------------
-spec get(pdb_prefix(), pdb_key(), get_opts()) -> pdb_value() | undefined.

get({Prefix, SubPrefix} = FullPrefix, Key, Opts)
when (is_binary(Prefix) orelse is_atom(Prefix))
andalso (is_binary(SubPrefix) orelse is_atom(SubPrefix)) ->
    PKey = prefixed_key(FullPrefix, Key),
    Default = get_option(default, Opts, undefined),
    ResolveMethod = get_option(resolver, Opts, lww),
    AllowPut = get_option(allow_put, Opts, true),
    case get_object(PKey) of
        undefined ->
            Default;
        Existing ->
            %% Aa Dotted Version Vector Set is returned.
            %% When reading the value for a subsequent call to put/3 the
            %% context can be obtained using pdb_object:context/1. Values can
            %% obtained w/ pdb_object:values/1.
            maybe_tombstone(
                maybe_resolve(PKey, Existing, ResolveMethod, AllowPut), Default)
    end.


%% -----------------------------------------------------------------------------
%% @doc Returns a Dotted Version Vector Set or undefined.
%% When reading the value for a subsequent call to put/3 the
%% context can be obtained using pdb_object:context/1. Values can
%% obtained w/ pdb_object:values/1.
%% @end
%% -----------------------------------------------------------------------------
get_object({{Prefix, SubPrefix}, _Key} = PKey)
when (is_binary(Prefix) orelse is_atom(Prefix))
andalso (is_binary(SubPrefix) orelse is_atom(SubPrefix)) ->
    case pdb_store_server:get(PKey) of
        {error, not_found} ->
            undefined;
        {ok, Existing} ->
            Existing
    end.


%% -----------------------------------------------------------------------------
%% @doc Same as get/1 but reads the value from `Node'
%% This is function is used by pdb_exchange_fsm.
%% @end
%% -----------------------------------------------------------------------------
-spec get_object(node(), pdb_pkey()) -> pdb_object() | undefined.

get_object(Node, PKey) when node() =:= Node ->
    get_object(PKey);

get_object(Node, {{Prefix, SubPrefix}, _Key} = PKey)
when is_binary(Prefix) andalso is_binary(SubPrefix) ->
    %% We call the corresponding pdb_store_worker instance
    %% in the remote node.
    %% This assumes all nodes have the same number of pdb partitions.
    gen_server:call(
        {pdb_store_worker:name(get_partition(PKey)), Node},
        {get_object, PKey},
        infinity
    ).

%% -----------------------------------------------------------------------------
%% @doc Same as fold(Fun, Acc0, FullPrefix, []).
%% @end
%% -----------------------------------------------------------------------------
-spec fold(fold_fun(), any(), pdb_prefix()) -> any().
fold(Fun, Acc0, FullPrefix) ->
    fold(Fun, Acc0, FullPrefix, []).


%% -----------------------------------------------------------------------------
%% @doc Fold over all keys and values stored under a given prefix/subprefix.
%% Available options are the same as those provided to iterator/2. To return
%% early, throw {break, Result} in your fold function.
%% @end
%% -----------------------------------------------------------------------------
-spec fold(fold_fun(), any(), pdb_prefix(), fold_opts()) -> any().
fold(Fun, Acc0, FullPrefix, Opts) ->
    It = iterator(FullPrefix, Opts),
    try
        fold_it(Fun, Acc0, It)
    catch
        {break, Result} -> Result
    after
        ok = iterator_close(It)
    end.

%% @private
fold_it(Fun, Acc, It) ->
    case iterator_done(It) of
        true ->
            Acc;
        false ->
            Next = Fun(iterator_key_values(It), Acc),
            fold_it(Fun, Next, iterate(It))
    end.


%% -----------------------------------------------------------------------------
%% @doc Same as to_list(FullPrefix, [])
%% @end
%% -----------------------------------------------------------------------------
-spec to_list(pdb_prefix()) -> [{pdb_key(), value_or_values()}].
to_list(FullPrefix) ->
    to_list(FullPrefix, []).


%% -----------------------------------------------------------------------------
%% @doc Return a list of all keys and values stored under a given
%% prefix/subprefix. Available options are the same as those provided to
%% iterator/2.
%% @end
%% -----------------------------------------------------------------------------
-spec to_list(pdb_prefix(), fold_opts()) -> [{pdb_key(), value_or_values()}].
to_list(FullPrefix, Opts) ->
    fold(fun({Key, ValOrVals}, Acc) ->
                 [{Key, ValOrVals} | Acc]
         end, [], FullPrefix, Opts).


%% -----------------------------------------------------------------------------
%% @doc Same as iterator(FullPrefix, []).
%% @end
%% -----------------------------------------------------------------------------
-spec iterator(pdb_prefix()) -> iterator().
iterator(FullPrefix) ->
    iterator(FullPrefix, []).


%% -----------------------------------------------------------------------------
%% @doc Return an iterator pointing to the first key stored under a prefix
%%
%% iterator/2 can take the following options:
%%
%% * resolver: either the atom `lww' or a function that resolves conflicts if
%% they are encounted (see get/3 for more details). Conflict resolution is
%% performed when values are retrieved (see iterator_value/1 and iterator_key_values/1).
%% If no resolver is provided no resolution is performed. The default is to not
%% provide a resolver.
%% * allow_put: whether or not to write and broadcast a resolved value.
%% defaults to `true'.
%% * default: Used when the value an iterator points to is a tombstone. default
%% is either an arity-1 function or a value. If a function, the key the
%% iterator points to is passed as the argument and the result is returned in
%% place of the tombstone. If default is a value, the value is returned in
%% place of the tombstone. This applies when using functions such as
%% iterator_values/1 and iterator_key_values/1.
%% * match: A tuple containing erlang terms and '_'s. Match can be used to
%% iterate over a subset of keys -- assuming the keys stored are tuples
%%
%% @end
%% -----------------------------------------------------------------------------
-spec iterator(pdb_prefix(), it_opts()) -> iterator().

iterator({Prefix, SubPrefix} = FullPrefix, Opts)
when (is_binary(Prefix) orelse is_atom(Prefix))
andalso (is_binary(SubPrefix) orelse is_atom(SubPrefix)) ->
    KeyMatch = proplists:get_value(match, Opts),
    Base = base_iterator(FullPrefix, KeyMatch),
    #iterator{base_iterator = Base, opts = Opts}.


%% -----------------------------------------------------------------------------
%% @doc Advances the iterator by one key, full-prefix or sub-prefix
%% @end
%% -----------------------------------------------------------------------------
-spec iterate
    (iterator()) ->
        iterator();
    (base_iterator() | remote_base_iterator()) ->
        base_iterator() | remote_base_iterator().

iterate(#iterator{base_iterator = Base0} = I) ->
    I#iterator{base_iterator = iterate(Base0)};

iterate(#remote_base_iterator{ref = Ref, node = Node} = I) ->
    _ = gen_server:call({?MODULE, Node}, {iterate, Ref}, infinity),
    I;

iterate(#base_iterator{ref = undefined, partitions = []} = I) ->
    %% We are done
    %% '$end_of_table';
    I;

iterate(#base_iterator{ref = undefined, partitions = [H|_]} = I0) ->
    %% We finished with the previous partition and we have
    %% more partitions to cover
    First = first_key(I0#base_iterator.prefix),
    Ref = case I0#base_iterator.keys_only of
        true ->
            pdb_store_server:key_iterator(H);
        false ->
            pdb_store_server:iterator(H)
    end,
    iterate(eleveldb:iterator_move(Ref, First), I0#base_iterator{ref = Ref});

iterate(#base_iterator{ref = Ref} = I) ->
    iterate(eleveldb:iterator_move(Ref, prefetch), I).


iterate({error, _}, #base_iterator{ref = Ref, partitions = [H|T]} = I) ->
    %% There are no more elements in the partition
    ok = pdb_store_server:iterator_close(H, Ref),
    iterate(I#base_iterator{ref = undefined, partitions = T});

iterate({ok, K}, #base_iterator{ref = Ref, partitions = [H|T]} = I) ->
    PKey = pdb:decode_key(K),
    case prefixed_key_matches(PKey, I) of
        true ->
            I#base_iterator{obj = PKey};
        false ->
            ok = pdb_store_server:iterator_close(H, Ref),
            iterate(I#base_iterator{ref = undefined, partitions = T})
    end;

iterate({ok, K, V},  #base_iterator{ref = Ref, partitions = [H|T]} = I) ->
    PKey = pdb:decode_key(K),
    case prefixed_key_matches(PKey, I) of
        true ->
            I#base_iterator{obj = {PKey, binary_to_term(V)}};
        false ->
            ok = pdb_store_server:iterator_close(H, Ref),
            iterate(I#base_iterator{ref = undefined, partitions = T})
    end.


%% -----------------------------------------------------------------------------
%% @doc Closes the iterator. This function must be called on all open iterators
%% @end
%% -----------------------------------------------------------------------------
-spec iterator_close(iterator() | base_iterator() | remote_base_iterator()) ->
    ok.

iterator_close(#iterator{base_iterator = Base}) ->
    iterator_close(Base);

iterator_close(#remote_base_iterator{ref = Ref, node = Node}) ->
    gen_server:call({?MODULE, Node}, {iterator_close, Ref}, infinity);

iterator_close(#base_iterator{ref = undefined}) ->
    ok;

iterator_close(#base_iterator{ref = Ref}) ->
    pdb_store_server:iterator_close(Ref).


%% -----------------------------------------------------------------------------
%% @doc Returns true if there is nothing more to iterate over
%% @end
%% -----------------------------------------------------------------------------
-spec iterator_done(iterator() | base_iterator() | remote_base_iterator()) ->
    boolean().

iterator_done(#iterator{base_iterator = Base}) ->
    iterator_done(Base);

iterator_done(#remote_base_iterator{ref = Ref, node = Node}) ->
    gen_server:call({?MODULE, Node}, {iterator_done, Ref}, infinity);

iterator_done(#base_iterator{ref = undefined, partitions = []}) ->
    true;

iterator_done(#base_iterator{}) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc Return the key and value(s) pointed at by the iterator. Before calling
%% this function, check the iterator is not complete w/ iterator_done/1. If a
%% resolver was passed to iterator/0 when creating the given iterator, siblings
%% will be resolved using the given function or last-write-wins (if `lww' is
%% passed as the resolver). If no resolver was used then no conflict resolution
%% will take place. If conflicts are resolved, the resolved value is written to
%% local metadata and a broadcast is submitted to update other nodes in the
%% cluster if `allow_put' is `true'. If `allow_put' is `false' the values are
%% resolved but are not written or broadcast. A single value is returned as the
%% second element of the tuple in the case values are resolved. If no
%% resolution takes place then a list of values will be returned as the second
%% element (even if there is only a single sibling).
%%
%% NOTE: if resolution may be performed this function must be called at most
%% once before calling iterate/1 on the iterator (at which point the function
%% can be called once more).
%% @end
%% -----------------------------------------------------------------------------
-spec iterator_key_values(iterator()) -> {pdb_key(), value_or_values()}.

iterator_key_values(#iterator{base_iterator = Base, opts = Opts} = I) ->
    Default = iterator_default(I),
    {Key, Obj} = iterator_value(Base),
    AllowPut = get_option(allow_put, Opts, true),
    case get_option(resolver, Opts, undefined) of
        undefined ->
            {Key, maybe_tombstones(pdb_object:values(Obj), Default)};
        Resolver ->
            Prefix = base_iterator_prefix(Base),
            PKey = prefixed_key(Prefix, Key),
            Value = maybe_tombstone(maybe_resolve(PKey, Obj, Resolver, AllowPut), Default),
            {Key, Value}
    end.


%% -----------------------------------------------------------------------------
%% @doc Return the key pointed at by the iterator. Before calling this function,
%%  check the iterator is not complete w/ iterator_done/1. No conflict resolution
%% will be performed as a result of calling this function.
%% @end
%% -----------------------------------------------------------------------------
-spec iterator_key(iterator()) -> pdb_key().
iterator_key(#iterator{base_iterator = Base}) ->
    {Key, _} = iterator_value(Base),
    Key.


%% -----------------------------------------------------------------------------
%% @doc Return all sibling values pointed at by the iterator. Before
%% calling this function, check the iterator is not complete w/ iterator_done/1.
%% No conflict resolution will be performed as a result of calling this
%% function.
%% @end
%% -----------------------------------------------------------------------------
-spec iterator_values(iterator()) -> [pdb_value() | pdb_tombstone()].
iterator_values(#iterator{base_iterator = Base} = I) ->
    Default = iterator_default(I),
    {_, Obj} = iterator_value(Base),
    maybe_tombstones(pdb_object:values(Obj), Default).


%% -----------------------------------------------------------------------------
%% @doc In case of an iterator(), returns a single value pointed at by the
%% iterator. In case of a base_iterator() returns the key and object or the
%% prefix pointed to by the iterator.
%%
%% In case of an iterator(), if there are conflicts and a resolver was
%% specified in the options when creating this iterator, they will be resolved.
%% Otherwise, and error is returned.
%% If conflicts are resolved, the resolved value is written locally and a
%% broadcast is performed to update other nodes
%% in the cluster if `allow_put' is `true' (the default value). If `allow_put'
%% is `false', values are resolved but not written or broadcast.
%%
%% NOTE: if resolution may be performed this function must be called at most
%% once before calling iterate/1 on the iterator (at which point the function
%% can be called once more).
%% @end
%% -----------------------------------------------------------------------------
-spec iterator_value
    (iterator()) ->
        pdb_value() | pdb_tombstone() | {error, conflict};
    (base_iterator() | remote_base_iterator()) ->
        {pdb_key(), pdb_object()} | pdb_prefix() | binary() | atom().


iterator_value(#iterator{base_iterator = Base, opts = Opts} = I) ->
    Default = iterator_default(I),
    {Key, Obj} = iterator_value(Base),
    AllowPut = get_option(allow_put, Opts, true),
    case get_option(resolver, Opts, undefined) of
        undefined ->
            case pdb_object:value_count(Obj) of
                1 ->
                    maybe_tombstone(pdb_object:value(Obj), Default);
                _ ->
                    {error, conflict}
            end;
        Resolver ->
            Prefix = base_iterator_prefix(Base),
            PKey = prefixed_key(Prefix, Key),
            maybe_tombstone(maybe_resolve(PKey, Obj, Resolver, AllowPut), Default)
    end;

iterator_value(#remote_base_iterator{ref = Ref, node = Node}) ->
    gen_server:call({?MODULE, Node}, {iterator_value, Ref}, infinity);

iterator_value(#base_iterator{obj = Obj}) ->
    Obj.


%% -----------------------------------------------------------------------------
%% @doc Returns the value returned when an iterator points to a tombstone. If
%% the default used when creating the given iterator is a function it will be
%% applied to the current key the iterator points at. If no default was
%% provided the tombstone value was returned.
%% This function should only be called after checking iterator_done/1.
%% @end
%% -----------------------------------------------------------------------------
-spec iterator_default(iterator()) ->
    pdb_tombstone() | pdb_value() | it_opt_default_fun().

iterator_default(#iterator{opts = Opts} = I) ->
    case proplists:get_value(default, Opts, ?TOMBSTONE) of
        Fun when is_function(Fun) ->
            Fun(iterator_key(I));
        Val -> Val
    end.


%% -----------------------------------------------------------------------------
%% @doc Return the local hash associated with a full-prefix or prefix. The hash
%% value is updated periodically and does not always reflect the most recent
%% value. This function can be used to determine when keys stored under a
%% full-prefix or prefix have changed.
%% If the tree has not yet been updated or there are no keys stored the given
%% (full-)prefix. `undefined' is returned.
%% @end
%% -----------------------------------------------------------------------------
-spec prefix_hash(pdb_prefix() | binary() | atom()) -> binary() | undefined.

prefix_hash(Prefix)
when is_tuple(Prefix) or is_atom(Prefix) or is_binary(Prefix) ->
    pdb_hashtree:prefix_hash(Prefix).


%% -----------------------------------------------------------------------------
%% @doc Same as put(FullPrefix, Key, Value, [])
%% @end
%% -----------------------------------------------------------------------------
-spec put(pdb_prefix(), pdb_key(), pdb_value() | pdb_modifier()) -> ok.
put(FullPrefix, Key, ValueOrFun) ->
    put(FullPrefix, Key, ValueOrFun, []).


%% -----------------------------------------------------------------------------
%% @doc Stores or updates the value at the given prefix and key locally and then
%% triggers a broadcast to notify other nodes in the cluster. Currently, there
%% are no put options.
%%
%% NOTE: because the third argument to this function can be a pdb_modifier(),
%% used to resolve conflicts on write, metadata values cannot be functions.
%% To store functions in metadata wrap them in another type like a tuple.
%% @end
%% -----------------------------------------------------------------------------
-spec put(pdb_prefix(), pdb_key(), pdb_value() | pdb_modifier(), put_opts()) ->
    ok.

put({Prefix, SubPrefix} = FullPrefix, Key, ValueOrFun, _Opts)
when (is_binary(Prefix) orelse is_atom(Prefix))
andalso (is_binary(SubPrefix) orelse is_atom(SubPrefix)) ->
    PKey = prefixed_key(FullPrefix, Key),
    Context = current_context(PKey),
    Updated = put_with_context(PKey, Context, ValueOrFun),
    broadcast(PKey, Updated).




%% -----------------------------------------------------------------------------
%% @doc Sets the value of a prefixed key.
%% @end
%% -----------------------------------------------------------------------------



%% -----------------------------------------------------------------------------
%% @doc Same as delete(FullPrefix, Key, [])
%% @end
%% -----------------------------------------------------------------------------
-spec delete(pdb_prefix(), pdb_key()) -> ok.
delete(FullPrefix, Key) ->
    delete(FullPrefix, Key, []).


%% -----------------------------------------------------------------------------
%% @doc Removes the value associated with the given prefix and key locally and
%% then triggers a broradcast to notify other nodes in the cluster. Currently
%% there are no delete options
%%
%% NOTE: currently deletion is logical and no GC is performed.
%% @end
%% -----------------------------------------------------------------------------
-spec delete(pdb_prefix(), pdb_key(), delete_opts()) -> ok.
delete(FullPrefix, Key, _Opts) ->
    put(FullPrefix, Key, ?TOMBSTONE, []).


%% -----------------------------------------------------------------------------
%% @doc Same as merge/2 but merges the object on `Node'
%% @end
%% -----------------------------------------------------------------------------
-spec merge(node(), {pdb_pkey(), undefined | pdb_context()}, pdb_object()) ->
    boolean().

merge(Node, {PKey, _Context}, Obj) ->
    Partition = get_partition(PKey),
    %% Merge is implemented by the worker as an atomic read-merge-write op
    %% TODO: Evaluate using the merge operation in RocksDB whcn available
    gen_server:call(
        {pdb_store_worker:name(Partition), Node},
        {merge, PKey, Obj},
        infinity
    ).





%% =============================================================================
%% BASE (former plumtree_manager)
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc Returns a full-prefix iterator: an iterator for all full-prefixes that
%% have keys stored under them.
%% When done with the iterator, iterator_close/1 must be called.
%% This iterator works across all existing store partitions, treating the set
%% of partitions as a single logical database. As a result, ordering is partial
%% per partition and not global across them.
%% @end
%% -----------------------------------------------------------------------------
-spec base_iterator() -> base_iterator().
base_iterator() ->
    base_iterator(undefined).


%% -----------------------------------------------------------------------------
%% @doc Returns a sub-prefix iterator for a given prefix.
%% When done with the iterator, iterator_close/1 must be called
%% @end
%% -----------------------------------------------------------------------------
-spec base_iterator(binary() | atom()) -> base_iterator().
base_iterator(Prefix) when is_binary(Prefix) or is_atom(Prefix) ->
    new_base_iterator(undefined, Prefix).


%% -----------------------------------------------------------------------------
%% @doc Return an iterator for keys stored under a prefix. If KeyMatch is
%% undefined then all keys will may be visted by the iterator. Otherwise only
%% keys matching KeyMatch will be visited.
%%
%% KeyMatch can be either:
%%
%% * an erlang term - which will be matched exactly against a key
%% * '_' - which is equivalent to undefined
%% * an erlang tuple containing terms and '_' - if tuples are used as keys
%% * this can be used to iterate over some subset of keys
%%
%% When done with the iterator, iterator_close/1 must be called.
%% @end
%% -----------------------------------------------------------------------------
-spec base_iterator(pdb_prefix(), term()) -> base_iterator().

base_iterator({Prefix, SubPrefix} = FullPrefix, KeyMatch)
when (is_binary(Prefix) orelse is_atom(Prefix))
andalso (is_binary(SubPrefix) orelse is_atom(SubPrefix)) ->
    new_base_iterator(FullPrefix, KeyMatch).


-spec base_iterator(undefined | pdb_prefix(), term(), non_neg_integer()) ->
    base_iterator().

base_iterator(undefined, KeyMatch, Partition) when is_integer(Partition) ->
    new_base_iterator(undefined, KeyMatch, Partition);

base_iterator({Prefix, SubPrefix} = FullPrefix, KeyMatch, Partition)
when (is_binary(Prefix) orelse is_atom(Prefix))
andalso (is_binary(SubPrefix) orelse is_atom(SubPrefix))
andalso is_integer(Partition) ->
    new_base_iterator(FullPrefix, KeyMatch, Partition).


%% -----------------------------------------------------------------------------
%% @doc Create an iterator on `Node'. This allows for remote iteration by having
%% the worker keep track of the actual iterator (since ets
%% continuations cannot cross node boundaries). The iterator created iterates
%% all full-prefixes.
%% Once created the rest of the iterator API may be used as usual. When done
%% with the iterator, iterator_close/1 must be called
%% @end
%% -----------------------------------------------------------------------------
-spec remote_base_iterator(node()) -> remote_base_iterator().
remote_base_iterator(Node) ->
    remote_base_iterator(Node, undefined).



%% -----------------------------------------------------------------------------
%% @doc Create an iterator on `Node'. This allows for remote iteration
%% by having the worker keep track of the actual iterator
%% (since ets continuations cannot cross node boundaries). When
%% `Perfix' is not a full prefix, the iterator created iterates all
%% sub-prefixes under `Prefix'. Otherse, the iterator iterates all keys
%% under a prefix. Once created the rest of the iterator API may be used as
%% usual.
%% When done with the iterator, iterator_close/1 must be called
%% @end
%% -----------------------------------------------------------------------------
-spec remote_base_iterator(
    node(), pdb_prefix() | binary() | atom() | undefined) ->
    remote_base_iterator().

remote_base_iterator(Node, Prefix) when is_atom(Prefix); is_binary(Prefix) ->
    Ref = gen_server:call(
        {?MODULE, Node},
        {open_remote_base_iterator, self(), undefined, Prefix},
        infinity
    ),
    #remote_base_iterator{ref = Ref, prefix = Prefix, node = Node};

remote_base_iterator(Node, FullPrefix) when is_tuple(FullPrefix) ->
    Ref = gen_server:call(
        {?MODULE, Node},
        {open_remote_base_iterator, self(), FullPrefix, undefined},
        infinity
    ),
    #remote_base_iterator{ref = Ref, prefix = FullPrefix, node = Node}.






prefixed_key_matches(PKey, #base_iterator{prefix = P, match = M}) ->
    prefixed_key_matches(PKey, P, M).

%% @private
prefixed_key_matches({_, _}, {undefined, undefined}, undefined) ->
    true;
prefixed_key_matches({_, Key}, {undefined, undefined}, Fun) ->
    Fun(Key);

prefixed_key_matches({{Prefix, _}, _}, {Prefix, undefined}, undefined) ->
    true;
prefixed_key_matches({{Prefix, _}, Key}, {Prefix, undefined}, Fun) ->
    Fun(Key);

prefixed_key_matches({{_, SubPrefix}, _}, {undefined, SubPrefix}, undefined) ->
    true;
prefixed_key_matches({{_, SubPrefix}, Key}, {undefined, SubPrefix}, Fun) ->
    Fun(Key);

prefixed_key_matches({FullPrefix, _}, FullPrefix, undefined) ->
    true;
prefixed_key_matches({{_, SubPrefix}, Key}, {undefined, SubPrefix}, Fun) ->
    Fun(Key);

prefixed_key_matches(_, _, _) ->
    false.


%% -----------------------------------------------------------------------------
%% @doc Returns the full-prefix or prefix being iterated by this iterator. If
%% the iterator is a full-prefix iterator undefined is returned.
%% @end
%% -----------------------------------------------------------------------------
-spec base_iterator_prefix(base_iterator() | remote_base_iterator()) ->
    pdb_prefix() | undefined | binary() | atom().

base_iterator_prefix(#remote_base_iterator{prefix = Prefix}) ->
    Prefix;
base_iterator_prefix(#base_iterator{prefix = undefined, match = undefined}) ->
    undefined;
base_iterator_prefix(#base_iterator{prefix = undefined, match = Prefix}) ->
    Prefix;
base_iterator_prefix(#base_iterator{prefix = Prefix}) ->
    Prefix.











%% =============================================================================
%% GEN_SERVER_ CALLBACKS
%% =============================================================================


%% @private
-spec init([]) ->
    {ok, state()}
    | {ok, state(), non_neg_integer() | infinity}
    | ignore
    | {stop, term()}.

init([]) ->
    ?MODULE = ets:new(
        ?MODULE,
        [named_table, {read_concurrency, true}, {write_concurrency, true}]
    ),
    {ok, #state{iterators = ?MODULE}}.

%% @private
-spec handle_call(term(), {pid(), term()}, state()) ->
    {reply, term(), state()}
    | {reply, term(), state(), non_neg_integer()}
    | {noreply, state()}
    | {noreply, state(), non_neg_integer()}
    | {stop, term(), term(), state()}
    | {stop, term(), state()}.

handle_call({open_remote_base_iterator, Pid, FullPrefix, KeyMatch}, _From, State) ->
    Iterator = new_remote_base_iterator(Pid, FullPrefix, KeyMatch, State),
    {reply, Iterator, State};

handle_call({iterate, RemoteRef}, _From, State) ->
    Next = iterate(RemoteRef, State),
    {reply, Next, State};

handle_call({iterator_value, RemoteRef}, _From, State) ->
    Res = from_remote_base_iterator(fun iterator_value/1, RemoteRef, State),
    {reply, Res, State};

handle_call({iterator_done, RemoteRef}, _From, State) ->
    Res = case from_remote_base_iterator(fun iterator_done/1, RemoteRef, State) of
              undefined -> true; %% if we don't know about iterator, treat it as done
              Other -> Other
          end,
    {reply, Res, State};

handle_call({iterator_close, RemoteRef}, _From, State) ->
    close_remote_base_iterator(RemoteRef, State),
    {reply, ok, State}.


%% @private
-spec handle_cast(term(), state()) ->
    {noreply, state()}
    | {noreply, state(), non_neg_integer()}
    | {stop, term(), state()}.

handle_cast(_Msg, State) ->
    {noreply, State}.


%% @private
-spec handle_info(term(), state()) ->
    {noreply, state()}
    | {noreply, state(), non_neg_integer()}
    | {stop, term(), state()}.

handle_info({'DOWN', ItRef, process, _Pid, _Reason}, State) ->
    close_remote_base_iterator(ItRef, State),
    {noreply, State}.


%% @private
-spec terminate(term(), state()) -> term().

terminate(_Reason, _State) ->
    ok.


%% @private
-spec code_change(term() | {down, term()}, state(), term()) -> {ok, state()}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% =============================================================================
%% API: PLUMTREE_BROADCAST_HANDLER CALLBACKS
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Deconstructs are broadcast that is sent using
%% `pdb_store_worker' as the handling module returning the message id
%% and payload.
%% @end
%% -----------------------------------------------------------------------------
-spec broadcast_data(pdb_broadcast()) ->
    {{pdb_pkey(), pdb_context()}, pdb_object()}.

broadcast_data(#pdb_broadcast{pkey=Key, obj=Obj}) ->
    Context = pdb_object:context(Obj),
    {{Key, Context}, Obj}.


%% -----------------------------------------------------------------------------
%% @doc Merges a remote copy of a metadata record sent via broadcast w/ the
%% local view for the key contained in the message id. If the remote copy is
%% causally older than the current data stored then `false' is returned and no
%% updates are merged. Otherwise, the remote copy is merged (possibly
%% generating siblings) and `true' is returned.
%% @end
%% -----------------------------------------------------------------------------
-spec merge(
    {pdb_pkey(), undefined | pdb_context()},
    undefined | pdb_object()) -> boolean().

merge({PKey, _Context}, Obj) ->
    gen_server:call(
        pdb_store_worker:name(get_partition(PKey)),
        {merge, PKey, Obj},
        infinity
    ).


%% -----------------------------------------------------------------------------
%% @doc Returns false if the update (or a causally newer update) has already
%% been received (stored locally).
%% @end
%% -----------------------------------------------------------------------------
-spec is_stale({pdb_pkey(), pdb_context()}) -> boolean().

is_stale({PKey, Context}) ->
    Existing = case ?MODULE:get(PKey) of
        {ok, Value} -> Value;
        {error, not_found} -> undefined
    end,
    pdb_object:is_stale(Context, Existing).


%% -----------------------------------------------------------------------------
%% @doc Returns the object associated with the given key and context
%% (message id) if the currently stored version has an equal context. otherwise
%% stale is returned.
%% Because it assumed that a grafted context can only be causally older than
%% the local view a stale response means there is another message that subsumes
%% the grafted one
%% @end
%% -----------------------------------------------------------------------------
-spec graft({pdb_pkey(), pdb_context()}) ->
    stale | {ok, pdb_object()} | {error, term()}.

graft({PKey, Context}) ->
    case ?MODULE:get(PKey) of
        {error, not_found} ->
            %% There would have to be a serious error in implementation to hit
            %% this case.
            %% Catch if here b/c it would be much harder to detect
            _ = lager:error(
                "object not found during graft for key: ~p", [PKey]),
            {error, {not_found, PKey}};
         Obj ->
            graft(Context, Obj)
    end.

graft(Context, Obj) ->
    case pdb_object:equal_context(Context, Obj) of
        false ->
            %% when grafting the context will never be causally newer
            %% than what we have locally. Since its not equal, it must be
            %% an ancestor. Thus we've sent another, newer update that contains
            %% this context's information in addition to its own.  This graft
            %% is deemed stale
            stale;
        true ->
            {ok, Obj}
    end.


%% -----------------------------------------------------------------------------
%% @doc Trigger an exchange
%% @end
%% -----------------------------------------------------------------------------
-spec exchange(node()) -> {ok, pid()} | {error, term()}.

exchange(Peer) ->
    Timeout = app_helper:get_env(pdb, metadata_exchange_timeout, 60000),
    case pdb_exchange_fsm:start(Peer, Timeout) of
        {ok, Pid} ->
            {ok, Pid};
        {error, Reason} ->
            {error, Reason};
        ignore ->
            {error, ignore}
    end.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
current_context(PKey) ->
    case pdb_store_server:get(PKey) of
        {ok, CurrentMeta} -> pdb_object:context(CurrentMeta);
        {error, not_found} -> pdb_object:empty_context()
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc The most recently read context
%% should be passed as the second argument to prevent unneccessary
%% siblings.
%% Context is a dvvset.
%% @end
%% -----------------------------------------------------------------------------
put_with_context(PKey, undefined, ValueOrFun) ->
    %% empty list is an empty dvvset
    put_with_context(PKey, [], ValueOrFun);

put_with_context({{Prefix, SubPrefix}, _Key} = PKey, Context, ValueOrFun)
when (is_binary(Prefix) orelse is_atom(Prefix))
andalso (is_binary(SubPrefix) orelse is_atom(SubPrefix)) ->
    gen_server:call(
        pdb_store_worker:name(get_partition(PKey)),
        {put, PKey, Context, ValueOrFun},
        infinity
    ).


%% @private
maybe_resolve(PKey, Existing, Method, AllowPut) ->
    SibCount = pdb_object:value_count(Existing),
    maybe_resolve(PKey, Existing, SibCount, Method, AllowPut).


%% @private
maybe_resolve(_PKey, Existing, 1, _Method, _AllowPut) ->
    pdb_object:value(Existing);

maybe_resolve(PKey, Existing, _, Method, AllowPut) ->
    Reconciled = pdb_object:resolve(Existing, Method),
    RContext = pdb_object:context(Reconciled),
    RValue = pdb_object:value(Reconciled),
    case AllowPut of
        false ->
            ok;
        true ->
            Stored = put_with_context(PKey, RContext, RValue),
            broadcast(PKey, Stored)
    end,
    RValue.

%% @private
maybe_tombstones(Values, Default) ->
    [maybe_tombstone(Value, Default) || Value <- Values].

%% @private
maybe_tombstone(?TOMBSTONE, Default) ->
    Default;
maybe_tombstone(Value, _Default) ->
    Value.

%% @private
broadcast(PKey, Obj) ->
    Broadcast = #pdb_broadcast{pkey = PKey, obj  = Obj},
    plumtree_broadcast:broadcast(Broadcast, pdb).


%% @private
-spec prefixed_key(pdb_prefix(), pdb_key()) -> pdb_pkey().
prefixed_key(FullPrefix, Key) ->
    {FullPrefix, Key}.


%% @private
get_option(Key, Opts, Default) ->
    case lists:keyfind(Key, 1, Opts) of
        {Key, Value} ->
            Value;
        _ ->
            Default
    end.





%% =============================================================================
%% PRIVATE: BASE
%% =============================================================================



%% =============================================================================
%% PRIVATE
%% =============================================================================

first_key(undefined) -> first;
first_key({undefined, undefined}) -> first;
first_key({Prefix, undefined}) -> sext:encode({{Prefix, ''}, ''});
first_key({_, _} = FullPrefix) -> sext:encode({FullPrefix, ''}).


%% @private
new_remote_base_iterator(
    Pid, FullPrefix, KeyMatch, #state{iterators = Iterators}) ->
    Ref = monitor(process, Pid),
    Iterator = new_base_iterator(FullPrefix, KeyMatch),
    ets:insert(Iterators, [{Ref, Iterator}]),
    Ref.


%% @private
from_remote_base_iterator(Fun, Ref, State) ->
    case ets:lookup(State#state.iterators, Ref) of
        [] -> undefined;
        [{Ref, It}] -> Fun(It)
    end.


%% @private
close_remote_base_iterator(Ref, #state{iterators = Iterators} = State) ->
    from_remote_base_iterator(fun iterator_close/1, Ref, State),
    ets:delete(Iterators, Ref).


%% @private
new_base_iterator(FullPrefix, KeyMatch) ->
    new_base_iterator(FullPrefix, KeyMatch, pdb:partitions(), false).

%% @private
new_base_iterator(FullPrefix, KeyMatch, Partition) ->
    new_base_iterator(FullPrefix, KeyMatch, [Partition], false).

%% @private
new_base_iterator(FullPrefix, KeyMatch, Partitions, KeysOnly) ->
    I = #base_iterator{
        prefix = FullPrefix,
        match = KeyMatch,
        keys_only = KeysOnly,
        obj = undefined,
        ref = undefined,
        partitions = Partitions
    },
    %% We fetch the first key
    iterate(I).
