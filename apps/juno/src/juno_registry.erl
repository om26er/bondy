%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

-module(juno_registry).
-include_lib("wamp/include/wamp.hrl").

-define(ANY, <<"*">>).

%% -define(DEFAULT_LIMIT, 1000).
-define(SUBSCRIPTION_TABLE_NAME, subscription).
-define(SUBSCRIPTION_INDEX_TABLE_NAME, subscription_index).
-define(REGISTRATION_TABLE_NAME, registration).
-define(REGISTRATION_INDEX_TABLE_NAME, registration_index).


-record(entry, {
    key                     ::  entry_key(),
    uri                     ::  uri(),
    match_policy            ::  match_policy(),
    criteria                ::  [{'=:=', Field :: binary(), Value :: any()}],
    created                 ::  calendar:date_time(),
    options                 ::  map()
}).

-record(index, {
    key                     ::  tuple(),  % dynamically generated
    entry_key               ::  entry_key()
}).

-type entry_key()           ::  {
                                    RealmUri    ::  uri(),
                                    SessionId   ::  id(),   % the owner
                                    EntryId     ::  id()
                                }.
-type entry()               ::  #entry{}.
-type entry_type()          ::  registration | subscription.

-export_type([entry/0]).
-export_type([entry_type/0]).

-export([about/1]).
-export([add/4]).
-export([created/1]).
-export([criteria/1]).
-export([entries/1]).
-export([entries/2]).
-export([entries/3]).
-export([entries/4]).
-export([id/1]).
-export([match_policy/1]).
-export([match/1]).
-export([match/3]).
-export([match/4]).
-export([options/1]).
-export([realm_uri/1]).
-export([remove_all/2]).
-export([remove/3]).
-export([session_id/1]).



%% =============================================================================
%% API
%% =============================================================================


-spec id(entry()) -> id().
id(#entry{key = {_, _, Val}}) -> Val.


-spec realm_uri(entry()) -> uri().
realm_uri(#entry{key = {Val, _, _}}) -> Val.


-spec session_id(entry()) -> id().
session_id(#entry{key = {_, Val, _}}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the uri this entry is about i.e. either a subscription topic_uri or
%% a registration procedure_uri.
%% @end
%% -----------------------------------------------------------------------------
-spec about(entry()) -> uri().
about(#entry{uri = Val}) -> Val.


-spec match_policy(entry()) -> binary().
match_policy(#entry{match_policy = Val}) -> Val.


-spec criteria(entry()) -> list().
criteria(#entry{criteria = Val}) -> Val.


-spec created(entry()) -> calendar:date_time().
created(#entry{created = Val}) -> Val.


-spec options(entry()) -> map().
options(#entry{options = Val}) -> Val.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(entry_type(), uri(), map(), juno_context:context()) -> {ok, id()}.
add(Type, Uri, Options, Ctxt) ->
    #{ realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    MatchPolicy = validate_match_policy(Options),
    MatchSessionId = case Type of
        registration -> '_';
        subscription -> SessionId
    end,
    Pattern = #entry{
        key = {RealmUri, MatchSessionId, '$1'},
        uri = Uri,
        match_policy = MatchPolicy,
        criteria = [], % TODO Criteria
        created = '_',
        options = '_'
    },
    Tab = entry_table(Type, RealmUri),

    MaybeAdd = fun
        (true) ->
            Entry = #entry{
                key = {RealmUri, SessionId, wamp_id:new(global)},
                uri = Uri,
                match_policy = MatchPolicy,
                criteria = [], % TODO Criteria
                created = calendar:local_time(),
                options = parse_options(Type, Options)
            },
            do_add(Type, Entry, Ctxt);
        (false) ->
            error(procedure_already_exists)
    end,

    case ets:match_object(Tab, Pattern) of
        [] ->
            %% No matching entry exists.
            MaybeAdd(true);

        [#entry{key = {_, _, EntryId}}] when Type == subscription ->
            %% In case of receiving a "SUBSCRIBE" message from the same
            %% _Subscriber_ and to already added topic, _Broker_ should
            %% answer with "SUBSCRIBED" message, containing the existing
            %% "Subscription|id".
            {ok, EntryId};

        [#entry{options = EOpts} | _] when Type == registration ->
            SharedEnabled = juno_context:is_feature_enabled(
                Ctxt, callee, shared_registration),
            NewPolicy = maps:get(invoke, Options, <<"single">>),
            PrevPolicy = maps:get(invoke, EOpts, <<"single">>),
            %% As a default, only a single Callee may register a procedure
            %% for an URI.
            %% Shared Registration (RFC 13.3.9)
            %% When shared registrations are supported, then the first
            %% Callee to register a procedure for a particular URI
            %% MAY determine that additional registrations for this URI
            %% are allowed, and what Invocation Rules to apply in case
            %% such additional registrations are made.
            %% When invoke is not 'single', Dealer MUST fail
            %% all subsequent attempts to register a procedure for the URI
            %% where the value for the invoke option does not match that of
            %% the initial registration.
            Flag = SharedEnabled andalso
                NewPolicy =/= <<"single">> andalso
                NewPolicy == PrevPolicy,

            MaybeAdd(Flag)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(entry_type(), juno_context:context()) -> ok.
remove_all(Type, Ctxt) ->
    #{realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    Pattern = #entry{
        key = {RealmUri, SessionId, '_'},
        uri = '_',
        match_policy = '_',
        criteria = '_',
        options = '_'
    },
    Tab = entry_table(Type, RealmUri),
    case ets:match_object(Tab, Pattern, 1) of
        '$end_of_table' ->
            %% There are no entries for this session
            ok;
        {[First], _} ->
            do_remove_all(First, Type, Tab, Ctxt)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(entry_type(), id(), juno_context:context()) -> ok.
remove(Type, EntryId, Ctxt) ->
    #{realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    Tab = entry_table(Type, RealmUri),
    Key = {RealmUri, SessionId, EntryId},
    case ets:take(Tab, Key) of
        [] ->
            %% The session had no entries with EntryId.
            error(no_such_subscription);
        [#entry{uri = Uri, match_policy = MP}] ->
            IdxTab = index_table(Type, RealmUri),
            IdxEntry = index_entry(EntryId, Uri, MP, Ctxt),
            true = ets:delete_object(IdxTab, IdxEntry),
            ok
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the list of entries for the active session.
%%
%% When called with a juno:context() it is equivalent to calling
%% entries/2 with the RealmUri and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(entry_type(), juno_context:context()) -> [entry()].
entries(Type, #{realm_uri := RealmUri, session_id := SessionId}) ->
    entries(Type, RealmUri, SessionId).


-spec entries(ets:continuation()) -> [entry()].
entries(Cont) ->
    ets:match_object(Cont).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of entries matching the RealmUri
%% and SessionId.
%%
%% Use {@link entries/3} and {@link entries/1} to limit the number
%% of entries returned.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(entry_type(), RealmUri :: uri(), SessionId :: id()) -> [entry()].
entries(Type, RealmUri, SessionId) ->
    session_entries(Type, RealmUri, SessionId, #{limit => infinity}).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of entries matching the RealmUri
%% and SessionId.
%%
%% Use {@link entries/3} to limit the number of entries returned.
%% @end
%% -----------------------------------------------------------------------------
-spec entries(
    entry_type(), RealmUri :: uri(), SessionId :: id(), Opts :: map()) ->
    {[entry()], Cont :: '$end_of_table' | term()}.
entries(Type, RealmUri, SessionId, Opts) ->
    session_entries(Type, RealmUri, SessionId, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(entry_type(), uri(), juno_context:context()) ->
    [{SessionId :: id(), pid(), EntryId :: id()}].
match(Type, Uri, Ctxt) ->
    #{realm_uri := RealmUri} = Ctxt,
    MS = index_ms(RealmUri, Uri),
    io:format("~nMS ~p~n", [MS]),
    Tab = index_table(Type, RealmUri),
    lookup_entries(Type, ets:select(Tab, MS)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(
    entry_type(), uri(), juno_context:context(), map()) ->
    [entry()]
    | {[entry()], ets:continuation()}
    | '$end_of_table'.
match(Type, Uri, Ctxt, Opts) ->
    #{realm_uri := RealmUri} = Ctxt,
    MS = index_ms(RealmUri, Uri, Opts),
    Tab = index_table(Type, RealmUri),
    case maps:get(limit, Opts, infinity) of
        infinity ->
            lookup_entries(Type, ets:select(Tab, MS));
        Limit ->
            lookup_entries(Type, ets:select(Tab, MS, Limit))
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(ets:continuation()) ->
    {[entry()], ets:continuation()} | '$end_of_table'.
match({Type, Cont}) when Type == registration orelse Type == subscription ->
    lookup_entries(Type, ets:select(Cont)).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_remove_all('$end_of_table', _, _, _) ->
    ok;
do_remove_all([], _, _, _) ->
    ok;
do_remove_all(#entry{} = S, Type, Tab, Ctxt) ->
    {RealmUri, _, EntryId} = Key = S#entry.key,
    Uri = S#entry.uri,
    MatchPolicy = S#entry.match_policy,
    IdxTab = index_table(Type, RealmUri),
    IdxEntry = index_entry(EntryId, Uri, MatchPolicy, Ctxt),
    true = ets:delete_object(Tab, S),
    true = ets:delete_object(IdxTab, IdxEntry),
    do_remove_all(ets:next(Tab, Key), Type, Tab, Ctxt);
do_remove_all({_, Sid, _} = Key, Type, Tab, #{session_id := Sid} = Ctxt) ->
    do_remove_all(ets:lookup(Tab, Key), Type, Tab, Ctxt);
do_remove_all(_, _, _, _) ->
    %% No longer our session
    ok.


%% @private
session_entries(Type, RealmUri, SessionId, Opts) ->
    Pattern = #entry{
        key = {RealmUri, SessionId, '_'},
        uri = '_',
        match_policy = '_',
        criteria = '_',
        options = '_'
    },
    Tab = entry_table(Type, RealmUri),
    case maps:get(limit, Opts, infinity) of
        infinity ->
            ets:match_object(Tab, Pattern);
        Limit ->
            ets:match_object(Tab, Pattern, Limit)
    end.



%% =============================================================================
%% PRIVATE - MATCHING
%% =============================================================================



%% @private
-spec validate_match_policy(map()) -> binary().
validate_match_policy(Options) when is_map(Options) ->
    P = maps:get(match, Options, <<"exact">>),
    P == <<"exact">> orelse P == <<"prefix">> orelse P == <<"wildcard">>
    orelse error({invalid_pattern_match_policy, P}),
    P.


%% @private
parse_options(subscription, Opts) ->
    parse_subscription_options(Opts);
parse_options(registration, Opts) ->
    parse_registration_options(Opts).


%% @private
parse_subscription_options(Opts) ->
    maps:without([match], Opts).


%% @private
parse_registration_options(Opts) ->
    maps:without([match], Opts).


%% @private
-spec entry_table(entry_type(), uri()) -> ets:tid().
entry_table(subscription, RealmUri) ->
    tuplespace:locate_table(
        ?SUBSCRIPTION_TABLE_NAME, RealmUri);
entry_table(registration, RealmUri) ->
    tuplespace:locate_table(
        ?REGISTRATION_TABLE_NAME, RealmUri).


%% @private
-spec index_table(entry_type(), uri()) -> ets:tid().
index_table(subscription, RealmUri) ->
    tuplespace:locate_table(?SUBSCRIPTION_INDEX_TABLE_NAME, RealmUri);
index_table(registration, RealmUri) ->
    tuplespace:locate_table(?REGISTRATION_INDEX_TABLE_NAME, RealmUri).


%% TODO move to wamp project
%% @private
%% @doc
%% Example:
%% uri_components(<<"com.mycompany.foo.bar">>) ->
%% [<<"com.mycompany">>, <<"foo">>, <<"bar">>].
%% @end
-spec uri_components(uri()) -> [binary()].
uri_components(Uri) ->
    case binary:split(Uri, <<".">>, [global]) of
        [TopLevelDomain, AppName | Rest] when length(Rest) > 0 ->
            Domain = <<TopLevelDomain/binary, $., AppName/binary>>,
            [Domain | Rest];
        _Other ->
            %% Invalid Uri
            error({badarg, Uri})
    end.


%% @private
do_add(Type, Entry, Ctxt) ->
    #entry{
        key = {RealmUri, _, EntryId},
        uri = Uri,
        match_policy = MatchPolicy
    } = Entry,

    SSTab = entry_table(Type, RealmUri),

    true = ets:insert(SSTab, Entry),

    IdxTab = index_table(Type, RealmUri),
    IdxEntry = index_entry(EntryId, Uri, MatchPolicy, Ctxt),
    true = ets:insert(IdxTab, IdxEntry),
    {ok, EntryId}.


%% @private
-spec index_entry(
    id(), uri(), binary(), juno_context:context()) -> #index{}.
index_entry(EntryId, Uri, Policy, Ctxt) ->
    #{realm_uri := RealmUri, session_id := SessionId} = Ctxt,
    Entry = #index{entry_key = {RealmUri, SessionId, EntryId}},
    Cs = [RealmUri | uri_components(Uri)],
    case Policy of
        <<"exact">> ->
            Entry#index{key = list_to_tuple(Cs)};
        <<"prefix">> ->
            Entry#index{key = list_to_tuple(Cs ++ [?ANY])};
        <<"wildcard">> ->
            %% Wildcard-matching allows to provide wildcards for *whole* URI
            %% components.
            Entry#index{key = list_to_tuple(Cs)}
    end.


%% @private
-spec index_ms(uri(), uri()) -> ets:match_spec().
index_ms(RealmUri, Uri) ->
    index_ms(RealmUri, Uri, #{}).


%% @private
-spec index_ms(uri(), uri(), map()) -> ets:match_spec().
index_ms(RealmUri, Uri, Opts) ->
    Cs = [RealmUri | uri_components(Uri)],
    ExactConds = [{'=:=', '$1', {const, list_to_tuple(Cs)}}],
    PrefixConds = prefix_conditions(Cs),
    WildcardCond = wilcard_conditions(Cs),
    AllConds = list_to_tuple(
        lists:append([['or'], ExactConds, PrefixConds, WildcardCond])),
    Conds = case maps:get(exclude, Opts, []) of
        [] ->
            [AllConds];
        SessionIds ->
            %% We exclude the provided SessionIds
            ExclConds = list_to_tuple([
                'and' |
                [{'=/=', '$2', {const, S}} || S <- SessionIds]
            ]),
            [list_to_tuple(lists:append(['andalso', AllConds, ExclConds]))]
    end,
    MP = #index{
        key = '$1',
        entry_key = {RealmUri, '$2', '$3'}
    },
    Proj = [{{RealmUri, '$2', '$3'}}],

    [
        { MP, Conds, Proj }
    ].


%% @private
-spec prefix_conditions(list()) -> list().
prefix_conditions(L) ->
    prefix_conditions(L, []).


%% @private
-spec prefix_conditions(list(), list()) -> list().
prefix_conditions(L, Acc) when length(L) == 2 ->
    lists:reverse(Acc);
prefix_conditions(L0, Acc) ->
    L1 = lists:droplast(L0),
    C = {'=:=', '$1', {const, list_to_tuple(L1 ++ [?ANY])}},
    prefix_conditions(L1, [C|Acc]).


%% @private
-spec wilcard_conditions(list()) -> list().
wilcard_conditions([H|T] = L) ->
    Ordered = lists:zip(T, lists:seq(2, length(T) + 1)),
    Cs0 = [
        {'or',
            {'=:=', {element, N, '$1'}, {const, E}},
            {'=:=', {element, N, '$1'}, {const, <<>>}}
        } || {E, N} <- Ordered
    ],
    Cs1 = [
        {'=:=',{element, 1, '$1'}, {const, H}},
        {'=:=', {size, '$1'}, {const, length(L)}} | Cs0],
    %% We need to use 'andalso' here and not 'and', otherwise the match spec
    %% will break when the {size, '$1'} /= {const, length(L)}
    %% This happens also because the evaluation order of 'or' and 'and' is
    %% undefined in match specs
    [list_to_tuple(['andalso' | Cs1])].


%% @private
lookup_entries(_Type, '$end_of_table') ->
    '$end_of_table';
lookup_entries(Type, {Keys, Cont}) ->
    {do_lookup_entries(Type, Keys), {Type, Cont}};
lookup_entries(Type, Keys) when is_list(Keys) ->
    do_lookup_entries(Type, Keys).

%% @private
do_lookup_entries(Type, Keys) ->
    do_lookup_entries(Keys, Type, []).

%% @private
do_lookup_entries([], _, Acc) ->
    lists:reverse(Acc);
do_lookup_entries([{RealmUri, _, _} = Key|T], Type, Acc) ->
    case ets:lookup(entry_table(Type, RealmUri), Key) of
        [] -> do_lookup_entries(T, Type, Acc);
        [Entry] -> do_lookup_entries(T, Type, [Entry|Acc])
    end.
