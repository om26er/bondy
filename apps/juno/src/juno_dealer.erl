%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2017. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% This module implements the capabilities of a Dealer. It is used by
%% {@link juno_router}.
%%
%% A Dealer is one of the two roles a Router plays. In particular a Dealer is
%% the middleman between an Caller and a Callee in an RPC interaction,
%% i.e. it works as a generic router for remote procedure calls
%% decoupling Callers and Callees.
%%
%% Callees register the procedures they provide with Dealers.  Callers
%% initiate procedure calls first to Dealers.  Dealers route calls
%% incoming from Callers to Callees implementing the procedure called,
%% and route call results back from Callees to Callers.
%%
%% A Caller issues calls to remote procedures by providing the procedure
%% URI and any arguments for the call. The Callee will execute the
%% procedure using the supplied arguments to the call and return the
%% result of the call to the Caller.
%%
%% The Caller and Callee will usually implement all business logic, while the
%% Dealer works as a generic router for remote procedure calls
%% decoupling Callers and Callees.
%%
%% Juno does not provide message transformations to ensure stability and safety.
%% As such, any required transformations should be handled by Callers and
%% Callees directly (notice that a Callee can act as a middleman implementing 
%% the required transformations).
%%
%% The message flow between _Callees_ and a _Dealer_ for registering and
%% unregistering endpoints to be called over RPC involves the following
%% messages:
%%
%%    1.  "REGISTER"
%%    2.  "REGISTERED"
%%    3.  "UNREGISTER"
%%    4.  "UNREGISTERED"
%%    5.  "ERROR"
%%
%%        ,------.          ,------.               ,------.
%%        |Caller|          |Dealer|               |Callee|
%%        `--+---'          `--+---'               `--+---'
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |       REGISTER       |
%%           |                 | <---------------------
%%           |                 |                      |
%%           |                 |  REGISTERED or ERROR |
%%           |                 | --------------------->
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |      UNREGISTER      |
%%           |                 | <---------------------
%%           |                 |                      |
%%           |                 | UNREGISTERED or ERROR|
%%           |                 | --------------------->
%%        ,--+---.          ,--+---.               ,--+---.
%%        |Caller|          |Dealer|               |Callee|
%%        `------'          `------'               `------'
%%
%% # Calling and Invocations
%%
%% The message flow between _Callers_, a _Dealer_ and _Callees_ for
%% calling procedures and invoking endpoints involves the following
%% messages:
%%
%%    1. "CALL"
%%
%%    2. "RESULT"
%%
%%    3. "INVOCATION"
%%
%%    4. "YIELD"
%%
%%    5. "ERROR"
%%
%%        ,------.          ,------.          ,------.
%%        |Caller|          |Dealer|          |Callee|
%%        `--+---'          `--+---'          `--+---'
%%           |       CALL      |                 |
%%           | ---------------->                 |
%%           |                 |                 |
%%           |                 |    INVOCATION   |
%%           |                 | ---------------->
%%           |                 |                 |
%%           |                 |  YIELD or ERROR |
%%           |                 | <----------------
%%           |                 |                 |
%%           | RESULT or ERROR |                 |
%%           | <----------------                 |
%%        ,--+---.          ,--+---.          ,--+---.
%%        |Caller|          |Dealer|          |Callee|
%%        `------'          `------'          `------'
%%
%%    The execution of remote procedure calls is asynchronous, and there
%%    may be more than one call outstanding.  A call is called outstanding
%%    (from the point of view of the _Caller_), when a (final) result or
%%    error has not yet been received by the _Caller_.
%%
%% # Remote Procedure Call Ordering
%%
%%    Regarding *Remote Procedure Calls*, the ordering guarantees are as
%%    follows:
%%
%%    If _Callee A_ has registered endpoints for both *Procedure 1* and
%%    *Procedure 2*, and _Caller B_ first issues a *Call 1* to *Procedure
%%    1* and then a *Call 2* to *Procedure 2*, and both calls are routed to
%%    _Callee A_, then _Callee A_ will first receive an invocation
%%    corresponding to *Call 1* and then *Call 2*. This also holds if
%%    *Procedure 1* and *Procedure 2* are identical.
%%
%%    In other words, WAMP guarantees ordering of invocations between any
%%    given _pair_ of _Caller_ and _Callee_. The current implementation 
%%    relies on Distributed Erlang which guarantees message ordering betweeen
%%    processes in different nodes.
%%
%%    There are no guarantees on the order of call results and errors in
%%    relation to _different_ calls, since the execution of calls upon
%%    different invocations of endpoints in _Callees_ are running
%%    independently.  A first call might require an expensive, long-running
%%    computation, whereas a second, subsequent call might finish
%%    immediately.
%%
%%    Further, if _Callee A_ registers for *Procedure 1*, the "REGISTERED"
%%    message will be sent by _Dealer_ to _Callee A_ before any
%%    "INVOCATION" message for *Procedure 1*.
%%
%%    There is no guarantee regarding the order of return for multiple
%%    subsequent register requests.  A register request might require the
%%    _Broker_ to do a time-consuming lookup in some database, whereas
%%    another register request second might be permissible immediately.
%% @end
%% =============================================================================
-module(juno_dealer).
-include_lib("wamp/include/wamp.hrl").
-include("juno.hrl").


-define(DEFAULT_LIMIT, 1000).
-define(INVOCATION_QUEUE, juno_rpc_promise).
-define(RPC_STATE_TABLE, juno_rpc_state).

-record(last_invocation, {
    key     ::  {uri(), uri()},
    value   ::  id()
}).

-record(promise, {
    invocation_request_id   ::  id(),
    procedure_uri           ::  uri(),
    call_request_id         ::  id(),
    caller_pid              ::  pid(),
    caller_session_id       ::  id(),
    callee_pid              ::  pid(),
    callee_session_id       ::  id()
}).
-type promise() :: #promise{}.


%% API
-export([close_context/1]).
-export([features/0]).
-export([handle_message/2]).
-export([is_feature_enabled/1]).
-export([register/3]).
-export([registrations/1]).
-export([registrations/2]).
-export([registrations/3]).
-export([match_registrations/2]).

%% =============================================================================
%% API
%% =============================================================================


-spec close_context(juno_context:context()) -> juno_context:context().
close_context(Ctxt) -> 
    %% Cleanup callee role registrations
    ok = unregister_all(Ctxt),
    %% Cleanup invocations queue
    cleanup_queue(Ctxt).


-spec features() -> map().
features() ->
    ?DEALER_FEATURES.


-spec is_feature_enabled(binary()) -> boolean().
is_feature_enabled(F) when is_binary(F) ->
    maps:get(F, ?DEALER_FEATURES).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: wamp_message(), Ctxt :: map()) -> ok | no_return().

handle_message(
    #register{procedure_uri = Uri, options = Opts, request_id = ReqId}, Ctxt) ->
    %% Check if it has callee role?
    Reply = case register(Uri, Opts, Ctxt) of
        {ok, RegId} ->
            wamp_message:registered(ReqId, RegId);
        {error, not_authorized} ->
            wamp_message:error(
                ?REGISTER, ReqId, #{}, ?WAMP_ERROR_NOT_AUTHORIZED);
        {error, procedure_already_exists} ->
            wamp_message:error(
                ?REGISTER,ReqId, #{}, ?WAMP_ERROR_PROCEDURE_ALREADY_EXISTS)
    end,
    juno:send(juno_context:peer_id(Ctxt), Reply);

handle_message(#unregister{} = M, Ctxt) ->
    Reply  = case unregister(M#unregister.registration_id, Ctxt) of
        ok ->
            wamp_message:unregistered(M#unregister.request_id);
        {error, not_authorized} ->
            wamp_message:error(
                ?UNREGISTER,
                M#unregister.request_id,
                #{},
                ?WAMP_ERROR_NOT_AUTHORIZED);
        {error, not_found} ->
            wamp_message:error(
                ?UNREGISTER,
                M#unregister.request_id,
                #{},
                ?WAMP_ERROR_NO_SUCH_REGISTRATION)
    end,
    juno:send(juno_context:peer_id(Ctxt), Reply);

handle_message(#cancel{} = M, Ctxt0) ->
    %% TODO check if authorized and if not throw wamp.error.not_authorized
    CallId = M#cancel.request_id,
    Opts = M#cancel.options,
    
    %% A response will be send asynchronously by another router process instance
    Fun = fun(InvocationId, Callee, Ctxt1) ->
        M = wamp_message:interrupt(InvocationId, Opts),
        ok = juno:send(Callee, M),
        {ok, Ctxt1}
    end,
    {ok, _Ctxt2} = dequeue_invocations(CallId, Fun, Ctxt0),
    ok;
   

handle_message(#yield{} = M, Ctxt0) ->
    %% A Callee is replying to a previous wamp_invocation() message 
    %% which we generated based on a Caller wamp_call() message
    %% We need to match the the wamp_yield() with the originating
    %% wamp_invocation() using the request_id, and with that match the
    %% wamp_call() request_id and find the caller pid.

    %% @TODO
    Fun = fun(CallId, Caller, Ctxt1) ->
        M = wamp_message:result(
            CallId, 
            M#yield.options,  %% TODO check if yield.options should be assigned to result.details
            M#yield.arguments, 
            M#yield.payload),
        ok = juno:send(Caller, M),
        {ok, Ctxt1}
    end,
    {ok, _Ctxt2} = dequeue_call(M#yield.request_id, Fun, Ctxt0),
    ok;

handle_message(#error{request_type = Type} = M, Ctxt0)
when Type == ?INVOCATION orelse Type == ?INTERRUPT ->
    Fun = fun(CallId, Caller, Ctxt1) ->
        M = wamp_message:error(
                Type, 
                CallId, 
                M#error.details, 
                M#error.error_uri, 
                M#error.arguments, 
                M#error.payload),
        ok = juno:send(Caller, M),
        {ok, Ctxt1}
    end,
    {ok, _Ctxt2} = dequeue_call(M#error.request_id, Fun, Ctxt0),
    ok;

handle_message(#call{procedure_uri = ?JUNO_USER_ADD} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_USER_DELETE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_USER_LIST} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_USER_LOOKUP} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_USER_UPDATE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_GROUP_ADD} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_GROUP_DELETE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_GROUP_LIST} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_GROUP_LOOKUP} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_GROUP_UPDATE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_SOURCE_ADD} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_SOURCE_DELETE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_SOURCE_LIST} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = ?JUNO_SOURCE_LOOKUP} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = <<"wamp.subscription.", _/binary>>} = M, Ctxt) ->
    juno_broker:handle_call(M, Ctxt);

handle_message(#call{procedure_uri = <<"wamp.registration.list">>} = M, Ctxt) ->
    ReqId = M#call.request_id,
    Res = #{
        <<"exact">> => [], % @TODO
        <<"prefix">> => [], % @TODO
        <<"wildcard">> => [] % @TODO
    },
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = <<"wamp.registration.lookup">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = <<"wamp.registration.match">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{procedure_uri = <<"wamp.registration.get">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(
    #call{procedure_uri = <<"wamp.registration.list_callees">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(
    #call{procedure_uri = <<"wamp.registration.count_callees">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{count => 0},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(juno_context:peer_id(Ctxt), M);

handle_message(#call{} = M, Ctxt0) ->
    %% TODO check if authorized and if not throw wamp.error.not_authorized
    Details = #{}, % @TODO

    %% invoke/5 takes a fun which takes the registration_id of the 
    %% procedure and the callee
    %% Based on procedure registration and passed options, we will
    %% determine how many invocations and to whom we should do.
    Fun = fun(RegId, Callee, Ctxt1) ->
        ReqId = juno_utils:get_id(global),
        Args = M#call.arguments,
        Payload = M#call.payload,
        M = wamp_message:invocation(ReqId, RegId, Details, Args, Payload),
        ok = juno:send(Callee, M, Ctxt1),
        {ok, ReqId, Ctxt1}
    end,

    %% A response will be send asynchronously by another router process instance
    {ok, _Ctxt2} = invoke(
        M#call.request_id,
        M#call.procedure_uri,
        Fun,
        M#call.options,
        Ctxt0),
    ok.


%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% Registers an RPC endpoint.
%% If the registration already exists, it fails with a
%% 'procedure_already_exists', 'not_authorized' error.
%% @end
%% -----------------------------------------------------------------------------
-spec register(uri(), map(), juno_context:context()) -> 
    {ok, id()} | {error, not_authorized | procedure_already_exists}.
register(<<"juno.", _/binary>>, _, _) ->
    %% Reserved namespace
    {error, not_authorized};

register(<<"wamp.", _/binary>>, _, _) ->
    %% Reserved namespace
    {error, not_authorized};

register(ProcUri, Options, Ctxt) ->
    case juno_registry:add(registration, ProcUri, Options, Ctxt) of
        {ok, Id, _IsFirst} -> 
            {ok, Id};
        {error, {already_exists, _}} -> 
            {error, procedure_already_exists}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Unregisters an RPC endpoint.
%% If the registration does not exist, it fails with a 'no_such_registration' or
%% 'not_authorized' error.
%% @end
%% -----------------------------------------------------------------------------
-spec unregister(id(), juno_context:context()) -> 
    ok | {error, not_authorized | not_found}.
unregister(<<"juno.", _/binary>>, _) ->
    %% Reserved namespace
    {error, not_authorized};

unregister(<<"wamp.", _/binary>>, _) ->
    %% Reserved namespace
    {error, not_authorized};

unregister(RegId, Ctxt) ->
    %% TODO Shouldn't we restrict this operation to the peer who registered it?
    juno_registry:remove(registration, RegId, Ctxt).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unregister_all(juno_context:context()) -> ok.
unregister_all(Ctxt) ->
    juno_registry:remove_all(registration, Ctxt).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the list of registrations for the active session.
%%
%% When called with a juno:context() it is equivalent to calling
%% registrations/2 with the RealmUri and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(juno_context:context() | juno_registry:continuation()) ->
    [juno_registry:entry()] 
    | {[juno_registry:entry()], juno_registry:continuation()}
    | '$end_of_table'. 
registrations(#{realm_uri := RealmUri} = Ctxt) ->
    registrations(RealmUri, juno_context:session_id(Ctxt));

registrations(Cont) ->
    juno_registry:entries(Cont).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the complete list of registrations matching the RealmUri
%% and SessionId.
%%
%% Use {@link registrations/3} and {@link registrations/1} to limit the
%% number of registrations returned.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(RealmUri :: uri(), SessionId :: id()) ->
    [juno_registry:entry()].
registrations(RealmUri, SessionId) ->
    juno_registry:entries(registration, RealmUri, SessionId, infinity).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the complete list of registrations matching the RealmUri
%% and SessionId.
%%
%% Use {@link registrations/3} to limit the number of registrations returned.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(RealmUri :: uri(), SessionId :: id(), non_neg_integer()) ->
    {[juno_registry:entry()], Cont :: '$end_of_table' | term()}.
registrations(RealmUri, SessionId, Limit) ->
    juno_registry:entries(registration, RealmUri, SessionId, Limit).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(uri(), juno_context:context()) ->
    [juno_registry:entry()].
match_registrations(ProcUri, Ctxt) ->
    case juno_registry:match(registration, ProcUri, Ctxt) of
        {L, '$end_of_table'} -> L;
        '$end_of_table' -> []
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(uri(), juno_context:context(), map()) ->
    {[juno_registry:entry()], ets:continuation()} | '$end_of_table'.
match_registrations(ProcUri, Ctxt, Opts) ->
    juno_registry:match(registration, ProcUri, Ctxt, Opts).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(juno_registry:continuation()) ->
    {[juno_registry:entry()], juno_registry:continuation()} | '$end_of_table'.
match_registrations(Cont) ->
    ets:select(Cont).




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Throws not_authorized
%% @end
%% -----------------------------------------------------------------------------
-spec invoke(id(), uri(), function(), map(), juno_context:context()) -> ok.
invoke(CallId, ProcUri, UserFun, Opts, Ctxt0) when is_function(UserFun, 3) ->
    S = juno_context:session(Ctxt0),
    SId = juno_session:id(S),
    Caller = juno_session:pid(S),
    Timeout = timeout(Opts),
    %%  A promise is used to implement a capability and a feature:
    %% - the capability to match wamp_yiled() or wamp_error() messages
    %%   to the originating wamp_call() and the Caller
    %% - call_timeout feature at the dealer level
    Template = #promise{
        procedure_uri = ProcUri, 
        call_request_id = CallId,
        caller_pid = Caller,
        caller_session_id = SId
    },

    Fun = fun(Entry, Ctxt1) ->
        CalleeSessionId = juno_registry:session_id(Entry),
        Callee = juno_session:pid(CalleeSessionId),
        RegId = juno_registry:entry_id(Entry),
        {ok, Id, Ctxt2} = UserFun(RegId, Callee, Ctxt1),
        Promise = Template#promise{
            invocation_request_id = Id,
            callee_session_id = CalleeSessionId,
            callee_pid = Callee
        }, 
        %% We enqueue the promise with a timeout
        ok = enqueue_promise(Id, Promise, Timeout, Ctxt2),
        {ok, Ctxt2}
    end,

    %% We asume that as with pubsub, the _Caller_ should not receive the
    %% invocation even if the _Caller_ is also a _Callee_ registered
    %% for that procedure.
    Regs = match_registrations(ProcUri, Ctxt0, #{exclude => [SId]}),
    do_invoke(Regs, Fun, Ctxt0).




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_invocations(id(), function(), juno_context:context()) -> 
    {ok, juno_context:context()}.
dequeue_invocations(CallId, Fun, Ctxt) when is_function(Fun, 3) ->
    % #{session := S} = Ctxt,
    % Caller = juno_session:pid(S),

    case dequeue_promise(call_request_id, CallId, Ctxt) of
        ok ->
            %% Promises for this call were either interrupted by us, 
            %% fulfilled or timed out and garbage collected, we do nothing 
            {ok, Ctxt};
        {ok, timeout} ->
            %% Promises for this call were either interrupted by us or 
            %% timed out or caller died, we do nothing
            {ok, Ctxt};
        {ok, P} ->
            #promise{
                invocation_request_id = ReqId,
                callee_pid = Pid,
                callee_session_id = SessionId
            } = P,
            {ok, Ctxt1} = Fun(ReqId, {SessionId, Pid}, Ctxt),
            %% We iterate until there are no more pending invocation for the
            %% call_request_id == CallId
            dequeue_invocations(CallId, Fun, Ctxt1)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_call(id(), function(), juno_context:context()) -> 
    {ok, juno_context:context()}.
dequeue_call(ReqId, Fun, Ctxt) when is_function(Fun, 2) ->
    case dequeue_promise(invocation_request_id, ReqId, Ctxt) of
        ok ->
            %% Promise was fulfilled or timed out and garbage collected,
            %% we do nothing 
            ok;
        {ok, timeout} ->
            %% Promise timed out, we do nothing
            ok;
        {ok, #promise{invocation_request_id = ReqId} = P} ->
            #promise{
                call_request_id = CallId,
                caller_pid = Pid,
                caller_session_id = SessionId
            } = P,
            Fun(CallId, {SessionId, Pid})
    end.




%% =============================================================================
%% PRIVATE - INVOCATION STRATEGIES (LOAD BALANCING, FAIL OVER, ETC)
%% =============================================================================


%% @private
do_invoke('$end_of_table', _, _) ->
    ok;

do_invoke({L, '$end_of_table'}, Fun, Ctxt) ->
    do_invoke(L, Fun, Ctxt);

do_invoke({L, Cont}, Fun, Ctxt) ->
    ok = do_invoke(Fun, L, Ctxt),
    do_invoke(match_registrations(Cont), Fun, Ctxt);

do_invoke(L, Fun, Ctxt) ->
    Triples = [{
        juno_registry:uri(E),
        maps:get(<<"invoke">>, juno_registry:options(E), <<"single">>),
        E
    } || E <- L],
    do_invoke(Triples, undefined, Fun, Ctxt).


%% @private
do_invoke([], undefined, _, _) ->
    ok;

do_invoke([{Uri, <<"single">>, E}|T], undefined, Fun, Ctxt0) ->
    {ok, Ctxt1} = apply_strategy(E, Fun, Ctxt0),
    do_invoke(T, {Uri, <<"single">>, []}, Fun, Ctxt1);

do_invoke(
    [{Uri, <<"single">>, _}|T], {Uri, <<"single">>, _} = Last, Fun, Ctxt) ->
    %% We drop subsequent entries for same Uri.
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    do_invoke(T, Last, Fun, Ctxt);

do_invoke([{Uri, Invoke, E}|T], undefined, Fun, Ctxt) ->
    do_invoke(T, {Uri, Invoke, [E]}, Fun, Ctxt);

do_invoke([{Uri, Invoke, E}|T], {Uri, Invoke, L}, Fun, Ctxt)  ->
    %% We build a list for subsequent entries for same Uri.
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    do_invoke(T, {Uri, Invoke, [E|L]}, Fun, Ctxt);

do_invoke([{Uri, <<"single">>, E}|T], {_, Invoke, L}, Fun, Ctxt0) ->
    {ok, Ctxt1} = apply_strategy({Invoke, L}, Fun, Ctxt0),
    {ok, Ctxt2} = apply_strategy(E, Fun, Ctxt1),
    do_invoke(T, {Uri, <<"single">>, []}, Fun, Ctxt2);

do_invoke([{Uri, Invoke, E}|T], {_, Invoke, L}, Fun, Ctxt0)  ->
    {ok, Ctxt1} = apply_strategy({Invoke, L}, Fun, Ctxt0),
    %% We build a list for subsequent entries for same Uri.
    do_invoke(T, {Uri, Invoke, [E]}, Fun, Ctxt1).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Implements load balancing and fail over invocation strategies
%% @end
%% -----------------------------------------------------------------------------
-spec apply_strategy(tuple(), function(), juno_context:context()) -> 
    {ok, juno_context:context()}.
apply_strategy({<<"first">>, L}, Fun, Ctxt) ->
    apply_first_available(L, Fun, Ctxt);

apply_strategy({<<"last">>, L}, Fun, Ctxt) ->
    apply_first_available(lists:reverse(L), Fun, Ctxt);

apply_strategy({<<"random">>, L}, Fun, Ctxt) ->
    apply_first_available(shuffle(L), Fun, Ctxt);

apply_strategy({<<"roundrobin">>, L}, Fun, Ctxt) ->
    apply_round_robin(L, Fun, Ctxt);

apply_strategy(Entry, Fun, Ctxt) ->
    Fun(Entry, Ctxt).


%% @private
apply_first_available([], _, Ctxt) ->
    {ok, Ctxt};

apply_first_available([H|T], Fun, Ctxt) ->
    Pid = juno_session:pid(juno_registry:session_id(H)),
    case process_info(Pid) == undefined of
        true ->
            apply_first_available(T, Fun, Ctxt);
        false ->
            Fun(H, Ctxt)
    end.


%% @private
-spec apply_round_robin(list(), function(), juno_context:context()) -> 
    {ok, juno_context:context()}.
apply_round_robin([], _, Ctxt) ->
    {ok, Ctxt};

apply_round_robin([H|_] = L, Fun, Ctxt) ->
    RealmUri = juno_context:realm_uri(Ctxt),
    Uri = juno_registry:uri(H),
    apply_round_robin(get_last_invocation(RealmUri, Uri), L, Fun, Ctxt).


%% @private
apply_round_robin(_, [], _, Ctxt) ->
    {ok, Ctxt};

apply_round_robin(undefined, [H|T], Fun, Ctxt) ->
    Pid = juno_session:pid(juno_registry:session_id(H)),
    case process_info(Pid) of
        undefined ->
            apply_round_robin(undefined, T, Fun, Ctxt);
        _ ->
            ok = update_last_invocation(
                juno_context:realm_uri(Ctxt),
                juno_registry:uri(H),
                juno_registry:id(H)
            ),
            Fun(H, Ctxt)
    end;

apply_round_robin(RegId, L0, Fun, Ctxt) ->
    Folder = fun
        (X, {PreAcc, []}) ->
            case juno_registry:id(X) of
                RegId ->
                    {RegId, PreAcc, [X]};
                _ ->
                    {RegId, [X|PreAcc], []}
            end;
        (X, {Id, PreAcc, PostAcc}) ->
            {Id, PreAcc, [X|PostAcc]}
    end,
    case lists:foldr(Folder, {[], []}, L0) of
        {Pre, []} ->
            apply_round_robin(undefined, Pre, Fun, Ctxt);
        {Pre, [H|T]} ->
            apply_round_robin(undefined, T ++ Pre ++ [H], Fun, Ctxt)
    end.


%% @private
get_last_invocation(RealmUri, Uri) ->
    case ets:lookup(rpc_state_table(RealmUri, Uri), {RealmUri, Uri}) of
        [] -> undefined;
        [Entry] -> Entry
    end.

update_last_invocation(RealmUri, Uri, Val) ->
    Entry = #last_invocation{key = {RealmUri, Uri}, value = Val},
    true = ets:insert(rpc_state_table(RealmUri, Uri), Entry),
    ok.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% A table that persists across calls and maintains the state of the load 
%% balancing of invocations 
%% @end
%% -----------------------------------------------------------------------------
rpc_state_table(RealmUri, Uri) ->
    tuplespace:locate_table(?RPC_STATE_TABLE, {RealmUri, Uri}).



%% =============================================================================
%% PRIVATE: PROMISES
%% =============================================================================



%% @private
-spec enqueue_promise(
    id(), promise(), pos_integer(), juno_context:context()) -> ok.
enqueue_promise(Id, Promise, Timeout, #{realm_uri := Uri}) ->
    #promise{call_request_id = CallId} = Promise,
    Key = {Uri, Id, CallId},
    Opts = #{key => Key, timeout => Timeout},
    tuplespace_queue:enqueue(?INVOCATION_QUEUE, Promise, Opts).


%% @private
dequeue_promise(invocation_request_id, Id, #{realm_uri := Uri}) ->
    dequeue_promise({Uri, Id, '_'});

dequeue_promise(call_request_id, Id, #{realm_uri := Uri}) ->
    dequeue_promise({Uri, '_', Id}).


%% @private
-spec dequeue_promise(tuple()) -> ok | {ok, timeout} | {ok, promise()}.
dequeue_promise(Key) ->
    case tuplespace_queue:dequeue(?INVOCATION_QUEUE, #{key => Key}) of
        empty ->
            %% The promise might have expired so we GC it.
            case tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Key}) of
                0 -> ok;
                _ -> {ok, timeout}
            end;
        Promise ->
            {ok, Promise}
    end.


%% @private
cleanup_queue(#{realm_uri := Uri, awaiting_call_ids := Set} = Ctxt) ->
    sets:fold(
        fun(Id, Acc) ->
            Key = {Uri, Id},
            ok = tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Key}),
            juno_context:remove_awaiting_call_id(Acc, Id)
        end,
        Ctxt,
        Set
    );
    
cleanup_queue(Ctxt) ->
    Ctxt.




%% =============================================================================
%% PRIVATE: UTILS
%% =============================================================================




%% @private
timeout(#{timeout := T}) when is_integer(T), T > 0 ->
    T;
timeout(#{timeout := 0}) ->
    infinity;
timeout(_) ->
    juno_config:request_timeout().


%% From https://erlangcentral.org/wiki/index.php/RandomShuffle
shuffle(List) ->
    %% Determine the log n portion then randomize the list.
    randomize(round(math:log(length(List)) + 0.5), List).


%% @private
randomize(1, List) ->
    randomize(List);
randomize(T, List) ->
    lists:foldl(
        fun(_E, Acc) -> randomize(Acc) end, 
        randomize(List), 
        lists:seq(1, (T - 1))).


%% @private
randomize(List) ->
    D = lists:map(fun(A) -> {rand:uniform(), A} end, List),
    {_, D1} = lists:unzip(lists:keysort(1, D)),
    D1.
