-module(eredis_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eredis.hrl").

-import(eredis, [create_multibulk/1]).

-define(assertReceive(Pattern),
        (fun () -> receive Msg -> ?assertMatch((Pattern), Msg)
                   after 5000 -> exit(timeout)
                   end
         end)()).

connect_test() ->
    ?assertMatch({ok, _}, eredis:start_link("127.0.0.1", 6379)),
    ?assertMatch({ok, _}, eredis:start_link("localhost", 6379)).

get_set_test() ->
    C = c(),
    ?assertMatch({ok, _}, eredis:q(C, ["DEL", foo])),

    ?assertEqual({ok, undefined}, eredis:q(C, ["GET", foo])),
    ?assertEqual({ok, <<"OK">>}, eredis:q(C, ["SET", foo, bar])),
    ?assertEqual({ok, <<"bar">>}, eredis:q(C, ["GET", foo])).


delete_test() ->
    C = c(),
    ?assertMatch({ok, _}, eredis:q(C, ["DEL", foo])),

    ?assertEqual({ok, <<"OK">>}, eredis:q(C, ["SET", foo, bar])),
    ?assertEqual({ok, <<"1">>}, eredis:q(C, ["DEL", foo])),
    ?assertEqual({ok, undefined}, eredis:q(C, ["GET", foo])).

mset_mget_test() ->
    C = c(),
    Keys = lists:seq(1, 1000),

    ?assertMatch({ok, _}, eredis:q(C, ["DEL" | Keys])),

    KeyValuePairs = [[K, K*2] || K <- Keys],
    ExpectedResult = [list_to_binary(integer_to_list(K * 2)) || K <- Keys],

    ?assertEqual({ok, <<"OK">>}, eredis:q(C, ["MSET" | lists:flatten(KeyValuePairs)])),
    ?assertEqual({ok, ExpectedResult}, eredis:q(C, ["MGET" | Keys])),
    ?assertMatch({ok, _}, eredis:q(C, ["DEL" | Keys])).

exec_test() ->
    C = c(),

    ?assertMatch({ok, _}, eredis:q(C, ["LPUSH", "k1", "b"])),
    ?assertMatch({ok, _}, eredis:q(C, ["LPUSH", "k1", "a"])),
    ?assertMatch({ok, _}, eredis:q(C, ["LPUSH", "k2", "c"])),

    ?assertEqual({ok, <<"OK">>}, eredis:q(C, ["MULTI"])),
    ?assertEqual({ok, <<"QUEUED">>}, eredis:q(C, ["LRANGE", "k1", "0", "-1"])),
    ?assertEqual({ok, <<"QUEUED">>}, eredis:q(C, ["LRANGE", "k2", "0", "-1"])),

    ExpectedResult = [[<<"a">>, <<"b">>], [<<"c">>]],

    ?assertEqual({ok, ExpectedResult}, eredis:q(C, ["EXEC"])),

    ?assertMatch({ok, _}, eredis:q(C, ["DEL", "k1", "k2"])).

exec_nil_test() ->
    C1 = c(),
    C2 = c(),

    ?assertEqual({ok, <<"OK">>}, eredis:q(C1, ["WATCH", "x"])),
    ?assertMatch({ok, _}, eredis:q(C2, ["INCR", "x"])),
    ?assertEqual({ok, <<"OK">>}, eredis:q(C1, ["MULTI"])),
    ?assertEqual({ok, <<"QUEUED">>}, eredis:q(C1, ["GET", "x"])),
    ?assertEqual({ok, undefined}, eredis:q(C1, ["EXEC"])),
    ?assertMatch({ok, _}, eredis:q(C1, ["DEL", "x"])).

pipeline_test() ->
    C = c(),

    P1 = [["DEL", b],
          ["SET", a, "1"],
          ["LPUSH", b, "3"],
          ["LPUSH", b, "2"]],

    ?assertMatch([{ok, _}, {ok, <<"OK">>}, {ok, <<"1">>}, {ok, <<"2">>}],
                 eredis:qp(C, P1)),

    P2 = [["MULTI"],
          ["GET", a],
          ["LRANGE", b, "0", "-1"],
          ["EXEC"]],

    ?assertEqual([{ok, <<"OK">>},
                  {ok, <<"QUEUED">>},
                  {ok, <<"QUEUED">>},
                  {ok, [<<"1">>, [<<"2">>, <<"3">>]]}],
                 eredis:qp(C, P2)),

    ?assertMatch({ok, _}, eredis:q(C, ["DEL", a, b])).

pipeline_mixed_test() ->
    C = c(),
    P1 = [["LPUSH", c, "1"] || _ <- lists:seq(1, 100)],
    P2 = [["LPUSH", d, "1"] || _ <- lists:seq(1, 100)],
    Expect = [{ok, list_to_binary(integer_to_list(I))} || I <- lists:seq(1, 100)],
    spawn(fun () ->
                  erlang:yield(),
                  ?assertEqual(Expect, eredis:qp(C, P1))
          end),
    spawn(fun () ->
                  ?assertEqual(Expect, eredis:qp(C, P2))
          end),
    timer:sleep(10),
    ?assertMatch({ok, _}, eredis:q(C, ["DEL", c, d])).

q_noreply_test() ->
    C = c(),
    ?assertEqual(ok, eredis:q_noreply(C, ["GET", foo])),
    ?assertEqual(ok, eredis:q_noreply(C, ["SET", foo, bar])),
    %% Even though q_noreply doesn't wait, it is sent before subsequent requests:
    ?assertEqual({ok, <<"bar">>}, eredis:q(C, ["GET", foo])).

qp_noreply_test() ->
    C = c(),
    ?assertEqual(ok, eredis:qp_noreply(C, [["GET", foo], ["SET", foo, bar]])),
    %% Even though qp_noreply doesn't wait, it is sent before subsequent requests:
    ?assertEqual({ok, <<"bar">>}, eredis:q(C, ["GET", foo])).

q_async_test() ->
    C = c(),
    ?assertEqual({ok, <<"OK">>}, eredis:q(C, ["SET", foo, bar])),
    {await, ReplyTag} = eredis:q_async(C, ["GET", foo], self()),
    receive
        {ReplyTag, Msg} ->
            ?assertEqual(Msg, {ok, <<"bar">>}),
            ?assertMatch({ok, _}, eredis:q(C, ["DEL", foo]))
    end.

qp_async_test() ->
    C = c(),
    {await, Tag1} = eredis:qp_async(C, [["SET", foo, 1]]),
    {await, Tag2} = eredis:qp_async(C, [["INCR", foo], ["INCR", foo]]),
    {await, Tag3} = eredis:qp_async(C, [["DEL", foo], ["INCR", foo]]),
    ?assertReceive({Tag1, [{ok, <<"OK">>}]}),
    ?assertReceive({Tag2, [{ok, <<"2">>}, {ok, <<"3">>}]}),
    ?assertReceive({Tag3, [{ok, <<"1">>}, {ok, <<"1">>}]}).

c() ->
    Res = eredis:start_link(),
    ?assertMatch({ok, _}, Res),
    {ok, C} = Res,
    C.



c_no_reconnect() ->
    Res = eredis:start_link("127.0.0.1", 6379, 0, "", no_reconnect),
    ?assertMatch({ok, _}, Res),
    {ok, C} = Res,
    C.

multibulk_test_() ->
    [?_assertEqual(<<"*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n">>,
                   list_to_binary(create_multibulk(["SET", "foo", "bar"]))),
     ?_assertEqual(<<"*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n">>,
                   list_to_binary(create_multibulk(['SET', foo, bar]))),

     ?_assertEqual(<<"*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\n123\r\n">>,
                   list_to_binary(create_multibulk(['SET', foo, 123]))),

     ?_assertThrow({cannot_store_floats, 123.5},
                   list_to_binary(create_multibulk(['SET', foo, 123.5])))
    ].

undefined_database_test() ->
    ?assertMatch({ok,_}, eredis:start_link("localhost", 6379, undefined)).

connection_failure_during_start_no_reconnect_test() ->
    process_flag(trap_exit, true),
    Res = eredis:start_link("localhost", 6378, 0, "", no_reconnect),
    ?assertMatch({error, _}, Res),
    IsDied = receive {'EXIT', _, _} -> died
             after 1000 -> still_alive end,
    process_flag(trap_exit, false),
    ?assertEqual(died, IsDied).

connection_failure_during_start_reconnect_test() ->
    process_flag(trap_exit, true),
    Res = eredis:start_link("localhost", 6378, 0, "", 100),
    ?assertMatch({ok, _}, Res),
    {ok, ClientPid} = Res,
    IsDied = receive {'EXIT', ClientPid, _} -> died
             after 400 -> still_alive end,
    process_flag(trap_exit, false),
    ?assertEqual(still_alive, IsDied).

tcp_closed_test() ->
    C = c(),
    tcp_closed_rig(C).

tcp_closed_no_reconnect_test() ->
    C = c_no_reconnect(),
    tcp_closed_rig(C).

tcp_closed_rig(C) ->
    %% fire async requests to add to redis client queue and then trick
    %% the client into thinking the connection to redis has been
    %% closed. This behavior can be observed when Redis closes an idle
    %% connection just as a traffic burst starts.
    Socket = eredis_client:get_socket(C),
    DoSend = fun(tcp_closed) ->
                     ok = gen_tcp:close(Socket);
                (Cmd) ->
                     eredis:q(C, Cmd)
             end,
    %% attach an id to each message for later
    Msgs = [{1, ["GET", "foo"]},
            {2, ["GET", "bar"]},
            {3, tcp_closed}],
    Pids = [ remote_query(DoSend, M) || M <- Msgs ],
    Results = gather_remote_queries(Pids),
    ?assertEqual({error, closed}, proplists:get_value(1, Results)),
    ?assertEqual({error, closed}, proplists:get_value(2, Results)).

remote_query(Fun, {Id, Cmd}) ->
    Parent = self(),
    spawn(fun() ->
                  Result = Fun(Cmd),
                  Parent ! {self(), Id, Result}
          end).

gather_remote_queries(Pids) ->
    gather_remote_queries(Pids, []).

gather_remote_queries([], Acc) ->
    Acc;
gather_remote_queries([Pid | Rest], Acc) ->
    receive
        {Pid, Id, Result} ->
            gather_remote_queries(Rest, [{Id, Result} | Acc])
    after
        10000 ->
            error({gather_remote_queries, timeout})
    end.
