%% State in eredis_sub_client
-record(state, {
          transport :: transport(),
          host :: string() | undefined,
          port :: integer() | undefined,
          password :: binary() | undefined,
          reconnect_sleep :: integer() | undefined | no_reconnect,

          transport_module :: module() | undefined,
          socket :: gen_tcp:socket() | ssl:sslsocket() | undefined,
          transport_data_tag :: atom(),
          transport_closure_tag :: atom(),
          transport_error_tag :: atom(),

          parser_state :: #pstate{} | undefined,

          %% Channels we should subscribe to
          channels = [] :: [channel()],

          % The process we send pubsub and connection state messages to.
          controlling_process :: undefined | {reference(), pid()},

          % This is the queue of messages to send to the controlling
          % process.
          msg_queue :: eredis_queue(),

          %% When the queue reaches this size, either drop all
          %% messages or exit.
          max_queue_size :: integer() | inifinity,
          queue_behaviour :: drop | exit,

          % The msg_state keeps track of whether we are waiting
          % for the controlling process to acknowledge the last
          % message.
          msg_state = need_ack :: ready | need_ack
}).
