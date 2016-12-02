%%%-------------------------------------------------------------------
%%% This file is part of the CernVM File System.
%%%
%%% @doc cvmfs_lease public API
%%%
%%% @end
%%%
%%%-------------------------------------------------------------------

-module(cvmfs_lease).

-compile([{parse_transform, lager_transform}]).

-include_lib("stdlib/include/ms_transform.hrl").

-behaviour(gen_server).

%% API
-export([start_link/1
        ,request_lease/4, end_lease/1
        ,check_lease/1
        ,get_leases/0, clear_leases/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

%% Records used as table entries

-record(lease, { path   :: binary()   % subpath which is locked
               , u_id   :: binary()   % user identifier
               , public :: binary()   % public string used for token generation
               , secret :: binary()   % secret used for token generation
               , time   :: integer()  % timestamp (time when lease acquired)
               }).


%%%===================================================================
%%% Type specifications
%%%===================================================================
-type new_lease_result() :: ok | {busy, TimeRemaining :: binary()}.
-type lease_check_result() :: {ok, Secret :: binary()} |
                              {error, invalid_lease | lease_expired}.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link(Args) -> {ok, Pid} | ignore | {error, Error}
                              when Args :: term(), Pid :: pid(),
                                   Error :: {already_start, pid()} | term().
start_link(_) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% Requests a new lease
%%
%% @end
%%--------------------------------------------------------------------
-spec request_lease(User, Path, Public, Secret) -> new_lease_result()
                                                       when User :: binary(),
                                                            Path :: binary(),
                                                            Public :: binary(),
                                                            Secret :: binary().
request_lease(User, Path, Public, Secret) ->
    gen_server:call(?MODULE, {lease_req, new_lease, {User, Path, Public, Secret}}).

%%--------------------------------------------------------------------
%% @doc
%% Gives up an existing lease
%%
%% @end
%%--------------------------------------------------------------------
-spec end_lease(Public :: binary()) -> ok.
end_lease(Public) ->
    gen_server:call(?MODULE, {lease_req, end_lease, Public}).

%%--------------------------------------------------------------------
%% @doc
%% Checks the validity of a lease
%%
%% @end
%%--------------------------------------------------------------------
-spec check_lease(Public) -> lease_check_result()
                                 when Public :: binary().
check_lease(Public) ->
    gen_server:call(?MODULE, {lease_req, check_lease, Public}).

%%--------------------------------------------------------------------
%% @doc
%% Returns list of all active leases
%%
%% @end
%%--------------------------------------------------------------------
-spec get_leases() -> Leases :: [#lease{}].
get_leases() ->
    gen_server:call(?MODULE, {lease_req, get_leases}).

%%--------------------------------------------------------------------
%% @doc
%% Clears all existing leases from the table.
%%
%% @end
%%--------------------------------------------------------------------
-spec clear_leases() -> ok.
clear_leases() ->
    gen_server:call(?MODULE, {lease_req, clear_leases}).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @end
%%--------------------------------------------------------------------
init(_) ->
    {ok, MnesiaSchemaLocation} = application:get_env(mnesia, schema_location),
    AllNodes = [node() | nodes()],
    CopyMode = case MnesiaSchemaLocation of
                   disc ->
                       {disc_copies, AllNodes};
                   ram ->
                       {ram_copies, AllNodes}
               end,
    mnesia:create_table(lease, [CopyMode
                               ,{type, set}
                               ,{attributes, record_info(fields, lease)}
                               ,{index, [public]}]),
    ok = mnesia:wait_for_tables([lease], 10000),
    lager:info("Lease table initialized"),
    {ok, {}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
handle_call({lease_req, new_lease, {User, Path, Public, Secret}}, _From, State) ->
    Reply = p_new_lease(User, Path, Public, Secret, State),
    lager:info("Request received: {new_lease, ~p} -> Reply: ~p"
              ,[{User, Path}, Reply]),
    {reply, Reply, State};
handle_call({lease_req, end_lease, Public}, _From, State) ->
    Reply = p_end_lease(Public),
    lager:info("Request received: {end_lease, ~p} -> Reply: ~p"
              ,[Public, Reply]),
    {reply, Reply, State};
handle_call({lease_req, check_lease, Public}, _From, State) ->
    Reply = p_check_lease(Public),
    lager:info("Request received: {check_lease, ~p} -> Reply: ~p"
              ,[Public, Reply]),
    {reply, Reply, State};
handle_call({lease_req, get_leases}, _From, State) ->
    Reply = p_get_leases(),
    lager:info("Request received: {get_leases} -> Reply: ~p"
              ,[Reply]),
    {reply, Reply, State};
handle_call({lease_req, clear_leases}, _From, State) ->
    Reply = p_clear_leases(),
    lager:info("Request received: {clear_leases} -> Reply: ~p"
              ,[Reply]),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
handle_cast(Msg, State) ->
    lager:info("Cast received: ~p -> noreply", [Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @end
%%--------------------------------------------------------------------
handle_info(Info, State) ->
    lager:warning("Unknown message received: ~p", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%--------------------------------------------------------------------
terminate(Reason, _State) ->
    lager:info("Terminating with reason: ~p", [Reason]),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @end
%%--------------------------------------------------------------------
code_change(OldVsn, State, _Extra) ->
    lager:info("Code change request received. Old version: ~p", [OldVsn]),
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec p_new_lease(User, Path, Public, Secret, State) -> new_lease_result()
                                                            when User :: binary(),
                                                                 Path :: binary(),
                                                                 Public :: binary(),
                                                                 Secret :: binary(),
                                                                 State :: map().
p_new_lease(User, Path, Public, Secret, _State) ->
    {ok, MaxLeaseTime} = application:get_env(cvmfs_services, max_lease_time),

    %% Match statement that selects all rows with a given repo,
    %% returning a list of {Path, Time} pairs
    MS = ets:fun2ms(fun(#lease{path = P} = Lease) when P =:= Path ->
                            Lease
                    end),

    AreOverlapping = fun(#lease{path = P}) ->
                             cvmfs_path_util:are_overlapping(P, Path)
                     end,

    T = fun() ->
                CurrentTime = erlang:system_time(milli_seconds),

                %% We select the rows related to a given repository
                %% We filter out entries which don't overlap with Path
                case lists:filter(AreOverlapping, mnesia:select(lease, MS)) of
                    %% An everlapping path was found
                    [#lease{path = Path, time = Time} | _] ->
                        RemainingTime = MaxLeaseTime - (CurrentTime - Time),
                        case RemainingTime > 0 of
                            %% The old lease is still valid, return busy message
                            true ->
                                {busy, RemainingTime};
                            %% The old lease is expired. Delete it and insert the new one
                            false ->
                                mnesia:delete({lease, Path}),
                                p_write_row(User, Path, Public, Secret)
                        end;
                    %% No overlapping paths were found; just insert the new entry
                    _ ->
                        p_write_row(User, Path, Public, Secret)
                end
        end,
    {atomic, Result} = mnesia:sync_transaction(T),
    Result.


-spec p_check_lease(Public) -> lease_check_result()
                                   when Public :: binary().
p_check_lease(Public) ->
    {ok, MaxLeaseTime} = application:get_env(cvmfs_services, max_lease_time),

    MS = ets:fun2ms(fun(#lease{public = P} = Lease) when P =:= Public ->
                            Lease
                    end),

    T = fun() ->
                CurrentTime = erlang:system_time(milli_seconds),

                case mnesia:select(lease, MS) of
                    [] ->
                        {error, invalid_lease};
                    [#lease{path = Path, secret = Secret, time = Time} | _]  ->
                        RemainingTime = MaxLeaseTime - (CurrentTime - Time),
                        case RemainingTime > 0 of
                            true ->
                                {ok, Secret};
                            false ->
                                mnesia:delete({lease, Path}),
                                {error, lease_expired}
                        end
                end
        end,
    {atomic, Result} = mnesia:sync_transaction(T),
    Result.


-spec p_end_lease(Public :: binary()) -> ok.
p_end_lease(Public) ->
    MS = ets:fun2ms(fun(#lease{public = Pub, path = Path}) when Pub =:= Public ->
                            Path
                    end),
    T = fun() ->
                case mnesia:select(lease, MS) of
                    [Path | _] ->
                        mnesia:delete({lease, Path});
                    [] ->
                        ok
                end
        end,
    {atomic, Result} = mnesia:sync_transaction(T),
    Result.


-spec p_get_leases() -> Leases :: [#lease{}].
p_get_leases() ->
    T = fun() ->
                mnesia:foldl(fun(Lease, Acc) -> [Lease | Acc] end, [], lease)
        end,
    {atomic, Result} = mnesia:transaction(T),
    Result.


-spec p_clear_leases() -> ok.
p_clear_leases() ->
    {atomic, Result} = mnesia:clear_table(lease),
    Result.


-spec p_write_row(User, Path, Public, Secret) -> ok
                                                     when User :: binary(),
                                                          Path :: binary(),
                                                          Public :: binary(),
                                                          Secret :: binary().
p_write_row(User, Path, Public, Secret) ->
    mnesia:write(#lease{path = Path,
                        u_id = User,
                        public = Public,
                        secret = Secret,
                        time = erlang:system_time(milli_seconds)}).
