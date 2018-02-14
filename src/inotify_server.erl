%%%-------------------------------------------------------------------
%%% Created : 28 Jan 2010 by Mats Cronqvist <masse@kreditor.se>
%%% Converted to an OTP application by Sven Heyll <sven.heyll@gmail.com>
%%%
%%% @doc
%%% A `gen_server' that provides access to low level Linux `inotify'.
%%% This is an internal module. Use {@link inotify} instead.
%%% @end
%%%-------------------------------------------------------------------

-module(inotify_server).

-behaviour(gen_server).

-author('Mats Cronqvist').
-author('Sven Heyll').

%% API
-export([start_link/0,
         watch/2,
         watch/3,
         unwatch/1]).

%% gen_server exports
-export([init/1,
         terminate/2,
         handle_cast/2,
         handle_info/2,
         handle_call/3,
         code_change/3]).

-define(SERVER, ?MODULE).

-include("inotify.hrl").

-record(ld,{port, fd}).

-define(log(T),
        error_logger:info_report(
          [process_info(self(), current_function),
           {line, ?LINE},
           T])).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
watch(File, EventTag) ->
    gen_server:cast(?SERVER, {watch, {File, EventTag, ?ALL}}).

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
watch(File, EventTag, Mask) ->
    gen_server:cast(?SERVER, {watch, {File, EventTag, Mask}}).

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
unwatch(EventTag) ->
    gen_server:cast(?SERVER, {unwatch, EventTag}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
init([]) ->
  process_flag(trap_exit, true),
  Port = open_port(),
  {ok, FD} = talk_to_port(Port , {open}),
  {ok, #ld{port = Port, fd = FD}}.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
terminate(_, LD) ->
  talk_to_port(LD#ld.port, {close, LD#ld.fd}).

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
handle_info({Port, {data,Msg}}, LD = #ld{port = Port}) ->
  maybe_call_back(binary_to_term(Msg)),
  {noreply, LD};

handle_info(Msg, LD) ->
  ?log({unknown_message, Msg}),
  {noreply, LD}.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
handle_cast(stop, LD) ->
  {stop,normal, LD};

handle_cast({watch,Watch},LD) ->
  {noreply, do_watch(Watch, LD)};

handle_cast({unwatch, Unwatch}, LD) ->
  {noreply, do_unwatch(Unwatch, LD)};

handle_cast(Msg, LD) ->
  ?log({unknown_message, Msg}),
  {noreply, LD}.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
open_port() ->
    E = filename:join([code:priv_dir(inotify), "inotify"]),
    open_port({spawn, E},[{packet, 2}, binary, exit_status]).

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
maybe_call_back({event, WD, Mask, Cookie, Name}) ->
    case get({wd, WD}) of
        undefined ->
            case Mask of
                [ignored] ->
                    ok;
                _ ->
                    ?log([{got_event_without_callback, WD, Mask, Cookie, Name}])
            end;
        Tag ->
            inotify_evt:publish(Tag, ?inotify_msg(Mask, Cookie, Name))
    end.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
do_watch({File, Tag, Mask},LD) ->
    try
        {ok, WD} = talk_to_port(LD#ld.port, {add, LD#ld.fd, File, Mask}),
        put({tag, Tag}, WD),
        put({wd, WD}, Tag),
        LD
    catch
        C:R ->
            ?log([{error_watching_file, File, Tag}, {C, R}]),
            LD
    end.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
do_unwatch(Tag, LD) ->
    case get({tag, Tag}) of
        undefined ->
            ?log([{not_watching, Tag}]),
            LD;
        WD ->
            try
                talk_to_port(LD#ld.port, {remove, LD#ld.fd, WD})
            catch
                C:R ->
                    ?log([{error_unwatching, Tag},{C, R}])
            end,
            erase({tag, Tag}),
            erase({wd, WD}),
            LD
    end.

%%--------------------------------------------------------------------
%% @private
%%--------------------------------------------------------------------
talk_to_port(Port,Msg) ->
    try
        erlang:port_command(Port, term_to_binary(Msg)),
        receive
            {Port, {data, D = <<131, 104, 2, _/binary>>}} ->
                binary_to_term(D)
        after 1000 ->
                throw(talk_to_port_timeout)
        end
    catch
        _:R ->
            throw({talking_to_port_failed, {R, Port, Msg}})
    end.
