%% @doc BEAM friendly spinlocks for Elixir/Erlang.
%%
%% This module provides a very simple API for managing locks
%% inside a BEAM instance. It's modeled on spinlocks, but works
%% through message passing rather than loops. Locks can have
%% multiple slots to enable arbitrary numbers of associated
%% processes. The moment a slot is freed, the next awaiting
%% process acquires the lock.
%%
%% All of this is done in a simple Erlang process so there's
%% very little dependency, and management is extremely simple.
-module(msglocks).
-compile(inline).

%% Public API
-export([new/1, new/2, acquire/1, attempt/1, execute/2, release/1]).
-export([init/1, handle_call/3]).

%% ===================================================================
%% Public API
%% ===================================================================

%% @doc Creates a new lock with `Max` slots.
-spec new(pos_integer()) ->
    {ok, pid()} | ignore | {error, term()}.
new(Max) ->
    new(Max, []).

%% @doc Creates a new lock with `Max` slots.
-spec new(pos_integer(), list()) ->
    {ok, pid()} | ignore | {error, term()}.
new(Max, Args) when
    is_number(Max),
    is_list(Args)
->
    case proplists:get_value(name, Args) of
        undefined ->
            gen_server:start_link(?MODULE, Max, []);
        Name ->
            gen_server:start_link(Name, ?MODULE, Max, [])
    end.

%% @doc Acquires a lock for the current process.
%%
%% This will block until a lock can be acquired.
-spec acquire(ServerName) -> ok when
    ServerName :: {local, atom()} | {global, term()} | {via, atom(), term()}.
acquire(Ref) ->
    gen_server:call(Ref, acquire, infinity).

%% @doc Attempts to acquire a lock for the current process.
%%
%% In the case there are no slots available, an error will be
%% returned immediately rather than waiting.
-spec attempt(ServerName) -> Result when
    ServerName :: {local, atom()} | {global, term()} | {via, atom(), term()},
    Result :: ok | {error, unavailable}.
attempt(Ref) ->
    gen_server:call(Ref, attempt).

%% @doc Executes a function when a lock can be acquired.
%%
%% The lock is automatically released after the function has
%% completed execution; there's no need to manually release.
-spec execute(ServerName, Exec) -> ok when
    ServerName :: {local, atom()} | {global, term()} | {via, atom(), term()},
    Exec :: fun(() -> any()).
execute(Ref, Fun) ->
    acquire(Ref),
    try Fun() of
        Res -> Res
    after
        release(Ref)
    end.

%% @doc Releases a lock held by the current process.
-spec release(ServerName) -> ok when
    ServerName :: {local, atom()} | {global, term()} | {via, atom(), term()}.
release(Ref) ->
    gen_server:call(Ref, release).

%%====================================================================
%% Callback functions
%%====================================================================

%% Initialization phase.
init(Max) ->
    {ok, {Max, #{}, queue:new()}}.

%% Handles a lock acquisition (blocks until one is available).
handle_call(acquire, Caller, {Max, Locks, Buffer} = State) ->
    case try_lock(Caller, State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {error, unavailable} ->
            {noreply, {Max, Locks, queue:snoc(Buffer, Caller)}}
    end;

%% Handles an attempt to acquire a lock.
handle_call(attempt, Caller, State) ->
    case try_lock(Caller, State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {error, unavailable} = E ->
            {reply, E, State}
    end;

%% Handles the release of a previously acquired lock.
handle_call(release, {From, _Ref}, {Max, Locks, Buffer} = State) ->
    NewState = case maps:take(From, Locks) of
        {ok, NewLocks} ->
            next_caller({Max, NewLocks, Buffer});
        error ->
            State
    end,
    {reply, ok, NewState}.

%%====================================================================
%% Private functions
%%====================================================================

%% Locks a caller in the internal locks map.
lock_caller({From, _Ref}, Locks) ->
    maps:put(From, ok, Locks).

%% Attempts to pass a lock to a waiting caller.
next_caller({Max, Locks, Buffer} = State) ->
    case queue:out(Buffer) of
        {empty, {[], []}} ->
            State;
        {{value, Next}, NewBuffer} ->
            gen_server:reply(Next, ok),
            {Max, lock_caller(Next, Locks), NewBuffer}
    end.

%% Attempts to acquire a lock for a calling process
try_lock(Caller, {Max, Locks, Buffer}) ->
    case maps:size(Locks) of
        S when S == Max ->
            {error, unavailable};
        _ ->
            {ok, {Max, lock_caller(Caller, Locks), Buffer}}
    end.

%% ===================================================================
%% Private test cases
%% ===================================================================

-ifdef(TEST).
    -include_lib("eunit/include/eunit.hrl").
-endif.