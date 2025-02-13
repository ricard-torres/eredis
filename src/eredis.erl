%%
%% Erlang Redis client
%%
%% Usage:
%%   {ok, Client} = eredis:start_link().
%%   {ok, <<"OK">>} = eredis:q(Client, ["SET", "foo", "bar"]).
%%   {ok, <<"bar">>} = eredis:q(Client, ["GET", "foo"]).

-module(eredis).
-include("eredis.hrl").
-include("eredis_defaults.hrl").

-define(is_host(Host),
        (is_list((Host)) orelse % regular hostname
         (tuple_size((Host)) =:= 2 andalso element(1, (Host)) =:= local))). % UNIX socket

-define(is_database(Database),
        (is_integer((Database)) orelse (Database) =:= undefined)).

-define(is_reconnect_sleep(ReconnectSleep),
        (is_integer((ReconnectSleep)) orelse (ReconnectSleep) =:= no_reconnect)).

-export([start_link/0, start_link/1, start_link/2, start_link/3, start_link/4,
         start_link/5, start_link/6, stop/1, q/2, q/3, qp/2, qp/3,
         q_noreply/2, qp_noreply/2, q_async/2, q_async/3, qp_async/2, qp_async/3]).

%% Exported for testing
-export([create_multibulk/1]).

%% Type of gen_server process id
-type client() :: pid() |
                  atom() |
                  {atom(),atom()} |
                  {global,term()} |
                  {via,atom(),term()}.

%%
%% PUBLIC API
%%

start_link() ->
    start_link([]).

start_link(Transport, Host)
  when is_atom(Transport) ->
    start_link(
      [{transport, Transport}, {host, Host}]
     );
start_link(Host, Port) ->
    start_link(
      [{host, Host}, {port, Port}]
     ).

start_link(Transport, Host, Port)
  when is_atom(Transport) ->
    start_link(
      [{transport, Transport}, {host, Host}, {port, Port}]
     );
start_link(Host, Port, Database) ->
    start_link(
      [{host, Host}, {port, Port}, {database, Database}]
     ).

start_link(Transport, Host, Port, Database)
  when is_atom(Transport) ->
    start_link(
      [{transport, Transport}, {host, Host}, {port, Port},
       {database, Database}]
     );
start_link(Host, Port, Database, Password) ->
    start_link(
      [{host, Host}, {port, Port}, {database, Database},
       {password, Password}]
     ).

start_link(Transport, Host, Port, Database, Password)
  when is_atom(Transport) ->
    start_link(
      [{transport, Transport}, {host, Host}, {port, Port},
       {database, Database}, {password, Password}]
     );
start_link(Host, Port, Database, Password, ReconnectSleep) ->
    start_link(
      [{host, Host}, {port, Port}, {database, Database},
       {password, Password}, {reconnect_sleep, ReconnectSleep}]
     ).

start_link(Transport, Host, Port, Database, Password, ReconnectSleep)
  when is_atom(Transport) ->
    start_link(
      [{transport, Transport}, {host, Host}, {port, Port},
       {database, Database}, {password, Password},
       {reconnect_sleep, ReconnectSleep}]
     );
start_link(Host, Port, Database, Password, ReconnectSleep, ConnectTimeout) ->
    start_link(
      [{host, Host}, {port, Port}, {database, Database},
       {password, Password}, {reconnect_sleep, ReconnectSleep},
       {connect_timeout, ConnectTimeout}]
     ).

start_link(Transport, Host, Port, Database, Password, ReconnectSleep, ConnectTimeout)
  when is_atom(Transport), ?is_host(Host), is_integer(Port), ?is_database(Database),
       is_list(Password), ?is_database(Database), is_integer(ConnectTimeout) ->
    eredis_client:start_link(Transport, Host, Port, Database, Password,
                             ReconnectSleep, ConnectTimeout).

%% @doc: Callback for starting from poolboy
-spec start_link(server_args()) -> {ok, Pid::pid()} | {error, Reason::term()}.
start_link(Args) ->
    Transport      = proplists:get_value(transport, Args, ?DEFAULT_TRANSPORT),
    Host           = proplists:get_value(host, Args, ?DEFAULT_HOST),
    Port           = proplists:get_value(port, Args, ?DEFAULT_PORT(Transport)),
    Database       = proplists:get_value(database, Args, ?DEFAULT_DATABASE),
    Password       = proplists:get_value(password, Args, ?DEFAULT_PASSWORD),
    ReconnectSleep = proplists:get_value(reconnect_sleep, Args, ?DEFAULT_RECONNECT_SLEEP),
    ConnectTimeout = proplists:get_value(connect_timeout, Args, ?DEFAULT_CONNECT_TIMEOUT),
    start_link(Transport, Host, Port, Database, Password, ReconnectSleep, ConnectTimeout).

stop(Client) ->
    eredis_client:stop(Client).

-spec q(Client::client(), Command::[any()]) ->
               {ok, return_value()} | {error, Reason::binary() | no_connection}.
%% @doc: Executes the given command in the specified connection. The
%% command must be a valid Redis command and may contain arbitrary
%% data which will be converted to binaries. The returned values will
%% always be binaries.
q(Client, Command) ->
    call(Client, Command, ?TIMEOUT).

q(Client, Command, Timeout) ->
    call(Client, Command, Timeout).


-spec qp(Client::client(), Pipeline::pipeline()) ->
                [{ok, return_value()} | {error, Reason::binary()}] |
                {error, no_connection}.
%% @doc: Executes the given pipeline (list of commands) in the
%% specified connection. The commands must be valid Redis commands and
%% may contain arbitrary data which will be converted to binaries. The
%% values returned by each command in the pipeline are returned in a list.
qp(Client, Pipeline) ->
    pipeline(Client, Pipeline, ?TIMEOUT).

qp(Client, Pipeline, Timeout) ->
    pipeline(Client, Pipeline, Timeout).

-spec q_noreply(Client::client(), Command::[any()]) -> ok.
%% @doc Executes the command but does not wait for a response and ignores any errors.
%% @see q/2
q_noreply(Client, Command) ->
    cast(Client, Command).

-spec qp_noreply(Client::client(), Pipeline::pipeline()) -> ok.
%% @doc Executes the pipeline but does not wait for a response and ignores any errors.
%% @see q/2
qp_noreply(Client, Pipeline) ->
    Request = {pipeline, [create_multibulk(Command) || Command <- Pipeline]},
    gen_server:cast(Client, Request).

-spec q_async(Client::client(), Command::[any()]) -> {await, Tag::reference()}.
% @doc Executes the command, and sends a message to this process with the response (with either error or success).
% Message is of the form `{Tag, Reply}', where `Reply' is the reply expected from `q/2'.
q_async(Client, Command) ->
    q_async(Client, Command, self()).

-spec q_async(Client::client(), Command::[any()], Pid::pid()|atom()) -> {await, Tag::reference()}.
%% @doc Executes the command, and sends a message to `Pid' with the response (with either or success).
%% @see 1_async/2
q_async(Client, Command, Pid) when is_pid(Pid) ->
    Tag = make_ref(),
    From = {Pid, Tag},
    Request = {request, create_multibulk(Command), From},
    gen_server:cast(Client, Request),
    {await, Tag}.

-spec qp_async(Client::client(), Pipeline::pipeline()) -> {await, Tag::reference()}.
% @doc Executes the pipeline, and sends a message to this process with the response (with either error or success).
% Message is of the form `{Tag, Reply}', where `Reply' is the reply expected from `qp/2'.
qp_async(Client, Pipeline) ->
    qp_async(Client, Pipeline, self()).

qp_async(Client, Pipeline, Pid) when is_pid(Pid) ->
    Tag = make_ref(),
    From = {Pid, Tag},
    Request = {pipeline, [create_multibulk(Command) || Command <- Pipeline], From},
    gen_server:cast(Client, Request),
    {await, Tag}.

%%
%% INTERNAL HELPERS
%%

call(Client, Command, Timeout) ->
    Request = {request, create_multibulk(Command)},
    gen_server:call(Client, Request, Timeout).

pipeline(_Client, [], _Timeout) ->
    [];
pipeline(Client, Pipeline, Timeout) ->
    Request = {pipeline, [create_multibulk(Command) || Command <- Pipeline]},
    gen_server:call(Client, Request, Timeout).

cast(Client, Command) ->
    Request = {request, create_multibulk(Command)},
    gen_server:cast(Client, Request).

-spec create_multibulk(Args::[any()]) -> Command::[[<<_:8,_:_*8>> | [binary() | [any()] | char()]],...].
%% @doc: Creates a multibulk command with all the correct size headers
create_multibulk(Args) ->
    ArgCount = [<<$*>>, integer_to_list(length(Args)), <<?NL>>],
    ArgsBin = lists:map(fun to_bulk/1, lists:map(fun to_binary/1, Args)),

    [ArgCount, ArgsBin].

to_bulk(B) when is_binary(B) ->
    [<<$$>>, integer_to_list(iolist_size(B)), <<?NL>>, B, <<?NL>>].

%% @doc: Convert given value to binary. Fallbacks to
%% term_to_binary/1. For floats, throws {cannot_store_floats, Float}
%% as we do not want floats to be stored in Redis. Your future self
%% will thank you for this.
to_binary(X) when is_list(X)    -> list_to_binary(X);
to_binary(X) when is_atom(X)    -> atom_to_binary(X, utf8);
to_binary(X) when is_binary(X)  -> X;
to_binary(X) when is_integer(X) -> integer_to_binary(X);
to_binary(X) when is_float(X)   -> throw({cannot_store_floats, X});
to_binary(X)                    -> term_to_binary(X).
