-module(server).
-compile(export_all).

% Start a server
start(Name, Port) ->
  net_kernel:start([Name, shortnames]),
  spawn(?MODULE, server, [Name, Port]).

server(Name, Port) ->
  {ok, LSock} = gen_tcp:listen(Port,[{packet,0},{active,false}]),

  % Each server has a pbalance and a match_adm process
  PidBalance = spawn(?MODULE, pbalance, [[]]),
  register(pid_balance, PidBalance),

  PidMatch = spawn(?MODULE, match_adm, [[]]),
  register(pid_matchadm, PidMatch),

  spawn(?MODULE, stat, []),
  dispatcher(LSock, 1, Name).

% Dispatcher accepts the connections and spawns a psocket for each client
dispatcher(LSock, Cont, Node) ->
  % Accept the connection
  {ok, CSock} = gen_tcp:accept(LSock),

% Start processes that will handle the connection with client
  % Sends messages that aren't the response of a command:
  % update messages for example
  NameListener = list_to_atom("listener"++integer_to_list(Cont)),
  PidListener = spawn(?MODULE, listener, [CSock]),
  register(NameListener, PidListener),

  % Responds to the inputs of the user
  NameSocket = list_to_atom("socket"++integer_to_list(Cont)),
  PidSocket = spawn(?MODULE, psocket, [CSock, none, true, NameSocket, NameListener]),
  register(NameSocket, PidSocket),

  dispatcher(LSock, Cont+1, Node).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% The processes pbalance and stat handle the balance of the nodes
pbalance(NodeList) ->
  io:format("~p~n",[NodeList]),
  receive
    {stat, Node, Tasks} -> case lists:keyfind(Node, 1, NodeList) of
                             false -> pbalance(NodeList++[{Node, Tasks}]);
                                 _ -> NewNodeList = lists:keyreplace(Node, 1, NodeList, {Node,Tasks}),
                                      pbalance (NewNodeList)
                           end;
    {connect, Pid} -> {LazyNode,_} = get_lazy_node (NodeList),
                      Pid!{spawn,LazyNode},
                      pbalance (NodeList)
  end.

stat() ->
  TotalTasks = statistics(total_active_tasks),

  % We inform all nodes of the current status
  pid_balance!{stat, node(), TotalTasks},
  lists:map(fun(X) -> {pid_balance,X}!{stat, node(), TotalTasks} end, nodes()),

  receive after 2000 -> ok end,
  stat().

get_lazy_node(NodeList) ->
  TasksList = lists:foldr(fun ({_,T},TList) -> [T]++TList end, [], NodeList),
  Min = lists:min(TasksList),
  lists:keyfind (Min, 2, NodeList).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% This processes handle the communication with the clients
% as explained before
psocket(CSock, UserName, Flag, Socket, Listener) ->
  case gen_tcp:recv(CSock,0) of
    {ok, Binary} ->
      pid_balance!{connect, self()},
      receive
        % We start a pcommand for each data package we receive. Note that
        % pcommand won't necessarily spawn in the same node that psocket
        {spawn, Node} -> io:format("pcommand process started in ~p ~n", [Node]),
                         spawn(Node, server, pcommand, [Binary, UserName, Flag, node(), Socket, Listener])
      end,
      receive
        {log, User} -> gen_tcp:send(CSock, "LOG " ++ atom_to_list(User)),
                       psocket(CSock, User, false, Socket, Listener);
        {games, ListGames} -> gen_tcp:send(CSock,"GAMES "++ListGames);
        {help, Text} -> gen_tcp:send(CSock,"HELP "++Text);
        log_fail -> gen_tcp:send(CSock, "LOG_FAIL ");
        already_log -> gen_tcp:send(CSock,"ALREADY_LOG "++atom_to_list(UserName));
        not_log -> gen_tcp:send(CSock,"NOT_LOG ");
        log_out -> gen_tcp:send(CSock,"EXIT "),
                   gen_tcp:close(CSock),
                   exit(normal);
        bad_index -> gen_tcp:send(CSock, "BAD_INDEX");
        match_created -> gen_tcp:send(CSock,"GAME ");
        already_registered -> gen_tcp:send(CSock,"ALREADY_REGISTERED ");
        joined -> gen_tcp:send(CSock,"JOIN ");
        well_delivered -> gen_tcp:send(CSock,"WELL_DELIVERED ");
        spect_ok  -> gen_tcp:send(CSock,"SPECT_OK ");
        no_valid_game -> gen_tcp:send(CSock,"NO_VALID_GAME ");
        room_full -> gen_tcp:send(CSock, "ROOM_FULL");
        incorrect -> gen_tcp:send(CSock,"INCORRECT ");
        end_spect_ok ->  gen_tcp:send(CSock,"END_SPECT_OK ");
        no_valid_user -> gen_tcp:send(CSock,"NO_VALID_USER ");
        no_args -> gen_tcp:send(CSock,"NO_ARGS ");
        not_allowed -> gen_tcp:send(CSock, "NOT_ALLOWED ")
      end;
    {error,closed} -> error
  end,
  psocket(CSock, UserName, Flag, Socket, Listener).

% This process redirects messages to a client which don't respond to a command
listener(CSock) ->
  receive
    {victory, Player, Game} -> gen_tcp:send(CSock, "WIN "++atom_to_list(Player)++" "++atom_to_list(Game));
    {update,Board,Game} -> gen_tcp:send(CSock,"UPD "++Board++" "++atom_to_list(Game));
    {opponent_end_game,UserName, MatchName} -> gen_tcp:send(CSock,"OPPONENT_END_GAME "++atom_to_list(UserName)++" "++atom_to_list(MatchName));
    {say,UserName,Msg} -> gen_tcp:send(CSock,"SAY "++atom_to_list(UserName)++" "++Msg);
    {end_spect,UserName,Game} -> gen_tcp:send(CSock,"END_SPECT "++atom_to_list(UserName)++" "++atom_to_list(Game));
    {turn, MatchName} -> gen_tcp:send(CSock,"TURN "++atom_to_list(MatchName));
    {draw, MatchName} -> gen_tcp:send(CSock,"DRAW "++atom_to_list(MatchName));
    bad_index -> gen_tcp:send(CSock, "BAD_INDEX");
    not_start -> gen_tcp:send(CSock,"NOT_START ");
    log_out -> exit(normal);
    no_valid_turn -> gen_tcp:send(CSock,"NO_VALID_TURN ");
    you_end_game -> gen_tcp:send(CSock,"YOU_END_GAME ")
  end,
  receive after 500 -> ok end,
  listener(CSock).

% This process will be globally registered, and will redirects the message to the listener of
% that client. It aims to simplify the internal communication.
user(Listener, ListenerNode) ->
  receive
    kill -> {Listener,ListenerNode}!log_out,
            exit(normal);
    M -> {Listener, ListenerNode}!M
  end,
  user(Listener, ListenerNode).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% The pcommand procces will understand the client commands and
% communicate to match_adm to realize the proper action
pcommand(Binary, UserName, Flag, Node, Socket, Listener) ->
  Input = lists:map(fun(X) -> list_to_atom(X) end, string:tokens(Binary," \n")),
  Args = length(Input),
  case Args of
    0 -> {Socket, Node}!no_args;
    _ -> Command = lists:nth(1, Input),
         case Flag of
           true -> case Command of
                     'HELP'-> case Args of
                                1 -> {Socket, Node}!{help, show_help()};
                                _ -> {Socket, Node}!incorrect
                              end;
                     'CON' -> case Args of
                                2 -> NewUserName = lists:nth(2,Input),
                                     PidUser = spawn(?MODULE, user, [Listener, Node]),
                                     case global:register_name(NewUserName, PidUser) of
                                       yes -> {Socket,Node}!{log, NewUserName};
                                       no -> PidUser!kill,
                                             {Socket, Node}!log_fail
                                     end;
                                _ -> {Socket, Node}!incorrect
                              end;
                      _  -> {Socket, Node}!not_log
                   end;
           false -> case Args of
                      1 -> case Command of
                             'LSG' -> pid_matchadm!{solicite_list, self()},
                                      receive
                                        {list, Games} -> {Socket, Node}!{games, lists:flatten(lists:map(fun(X) -> match_print(X) end, Games))}
                                      end;
                             'HELP'-> {Socket, Node}!{help, show_help()};
                             'BYE' -> pid_matchadm!{remove, UserName, self()},
                                      receive
                                        remove_ok -> global:send(UserName, kill),
                                                     {Socket, Node}!log_out
                                      end;
                              _    -> {Socket, Node}!incorrect
                           end;
                      2 -> Arg1 = lists:nth(2,Input),
                           case Command of
                             'NEW' -> pid_matchadm!{new, Arg1, UserName, self()},
                                      receive
                                        created -> {Socket, Node}!match_created;
                                        used_name -> {Socket, Node}!already_registered
                                      end;
                             'ACC' -> pid_matchadm!{join, Arg1, UserName, self()},
                                      receive
                                        no_valid_game -> {Socket,Node}!no_valid_game;
                                        joined -> {Socket, Node}!joined;
                                        room_full -> {Socket, Node}!room_full
                                      end;
                             'LEA' -> MatchName = Arg1,
                                      pid_matchadm!{end_spect, self()},
                                      receive
                                        {list, Games} -> PossibleGame = lists:filter(fun({G,_,_}) -> MatchName == G end,Games),
                                                         case PossibleGame of
                                                           [] -> {Socket, Node}!no_valid_game;
                                                           _  -> {G,_,_} = lists:nth(1,PossibleGame),
                                                                 global:send(G,{end_spect,UserName}),
                                                                 {Socket, Node}!end_spect_ok
                                                         end
                                      end;
                             'OBS' -> MatchName = Arg1,
                                      pid_matchadm!{spect, self()},
                                      receive
                                        {list, Games} -> PossibleGame = lists:filter(fun({G,_,_}) -> MatchName == G end,Games),
                                                         case PossibleGame of
                                                           [] -> {Socket, Node}!no_valid_game;
                                                           _  -> {G,_,_} = lists:nth(1,PossibleGame),
                                                                 global:send(G,{spect,UserName}),
                                                                 {Socket, Node}!spect_ok
                                                         end
                                      end;
                              _    -> {Socket, Node}!incorrect
                           end;
                      3 -> Arg1 = lists:nth(2, Input),
                           Arg2 = lists:nth(3, Input),
                           case (Command == 'PLA') and (Arg2 == 'END') of
                             true -> pid_matchadm!{ending, Arg1, UserName, self()},
                                     receive
                                       well_delivered -> {Socket, Node}!well_delivered;
                                       no_valid_game -> {Socket, Node}!no_valid_game;
                                       not_allowed -> {Socket, Node}!not_allowed
                                     end;
                              _   -> case Command of
                                       'SAY' -> User = Arg1,
                                                Users = global:registered_names(),
                                                case length(lists:filter(fun(X) -> X == User end,Users)) of
                                                  0 -> {Socket,Node}!no_valid_user;
                                                  _ -> global:send(User,{say,UserName,lists:subtract(Binary,"SAY "++atom_to_list(User))}),
                                                       {Socket,Node}!well_delivered
                                                end;
                                       _ -> {Socket, Node}!incorrect
                                    end
                           end;
                      4 -> Arg1 = lists:nth(2, Input),
                           Arg2 = lists:nth(3, Input),
                           Arg3 = lists:nth(4, Input),
                           case Command of
                             'PLA'-> MatchName = Arg1,
                                     X = atom_to_integer(Arg2),
                                     Y = atom_to_integer(Arg3),
                                     pid_matchadm!{movement, self()},
                                     receive
                                      {list, Games} -> PossibleGame = lists:filter(fun({G,_,_}) -> MatchName == G end, Games),
                                                       case PossibleGame of
                                                         [] -> {Socket, Node}!no_valid_game;
                                                          _ -> {_,P1,P2} = lists:nth(1, PossibleGame),
                                                               case (P1 == UserName) or (P2 == UserName) of
                                                                 true -> case is_movement_allowed(X,Y) of
                                                                           true -> {Socket, Node}!well_delivered,
                                                                                   receive after 200 -> ok end,
                                                                                   global:send(MatchName,{movement,X,Y,UserName});
                                                                           false -> {Socket, Node}!bad_index
                                                                         end;
                                                                 false -> {Socket, Node}!not_allowed
                                                               end
                                                       end
                                     end;
                             'SAY' -> User = Arg1,
                                      Users = global:registered_names(),
                                      case length(lists:filter(fun(X) -> X == User end,Users)) of
                                        0 -> {Socket,Node}!no_valid_user;
                                        _ -> global:send(User,{say,UserName,lists:subtract(Binary,"SAY "++atom_to_list(User))}),
                                             {Socket,Node}!well_delivered
                                      end;
                              _   -> {Socket, Node}!incorrect
                           end;
                      _ -> case Command of
                             'SAY' -> User = lists:nth(2,Input),
                                      Users = global:registered_names(),
                                      case length(lists:filter(fun(X) -> X == User end,Users)) of
                                        0 -> {Socket,Node}!no_valid_user;
                                        _ -> global:send(User,{say,UserName,lists:subtract(Binary,"SAY "++atom_to_list(User))}),
                                             {Socket,Node}!well_delivered
                                      end;
                                _ -> {Socket, Node}!incorrect
                          end
                    end
         end
  end.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Game administration processes:

% Administrates the games, create new rooms, deliver plays, etc...
match_adm(Games) ->
  receive
    {new, MatchName, UserName, PidCommand} -> PidGame = spawn(?MODULE, match, [UserName, none, [], MatchName]),
                                              NewGame = [{MatchName, UserName, none}],
                                              case global:register_name(MatchName, PidGame) of
                                                yes -> PidCommand!created,
                                                       lists:map(fun(X) -> {pid_matchadm,X}!{refresh,NewGame} end, nodes()),
                                                       match_adm(Games++NewGame);
                                                no -> PidCommand!used_name,
                                                      PidGame!kill
                                              end;
    {join, MatchName, UserName, PidCommand} -> PossibleGame = lists:filter(fun({G,_,_}) -> MatchName == G end, Games),
                                               case PossibleGame of
                                                 [] -> PidCommand!no_valid_game;
                                                 _  -> {_,_,P2} = lists:nth(1,PossibleGame),
                                                       case P2 of
                                                         none -> global:send(MatchName, {join, UserName}),
                                                                 lists:map(fun(X) -> {pid_matchadm,X}!{join_refresh, MatchName, UserName} end, nodes()),
                                                                 PidCommand!joined,
                                                                 match_adm(lists:map(fun(X) -> update(X, MatchName, UserName) end, Games));
                                                         _    -> PidCommand!room_full
                                                       end
                                               end;
    {ending, MatchName, UserName, PidCommand} -> PossibleGame = lists:filter(fun({G,_,_}) -> MatchName == G end,Games),
                                                 case PossibleGame of
                                                   [] -> PidCommand!no_valid_game;
                                                   _  -> {G,P1,P2} = lists:nth(1,PossibleGame),
                                                         case (P1 == UserName) or (P2 == UserName) of
                                                           true -> PidCommand!well_delivered,
                                                                   global:send(G,{ending,UserName}),
                                                                   lists:map(fun(X) -> {pid_matchadm,X}!{end_refresh,MatchName} end, nodes()),
                                                                   match_adm(lists:filter(fun ({X,_,_}) -> X /= MatchName end, Games));
                                                           false -> PidCommand!not_allowed
                                                         end
                                                 end;
    {spect, PidCommand} -> PidCommand!{list, Games};
    {end_spect, PidCommand} -> PidCommand!{list,Games};
    {refresh,NewGame} -> match_adm(Games++NewGame);
    {join_refresh,MatchName,UserName} -> match_adm(lists:map(fun(X) -> update(X,MatchName,UserName) end,Games));
    {end_refresh, MatchName} -> match_adm(lists:filter(fun ({G,_,_}) -> G /= MatchName end, Games));
    {remove_refresh, NewGames} -> match_adm(NewGames);
    {movement,PidCommand} -> PidCommand!{list,Games};
    {remove, UserName, PidCommand} -> GamesToRemove = lists:filter(fun({_,P1,P2}) -> (P1 == UserName) or (P2 == UserName) end, Games),
                                      NewGames = lists:filter(fun({_,P1,P2}) -> (P1 /= UserName) and (P2 /= UserName) end, Games),
                                      lists:map(fun({G,_,_}) -> global:send(G, {ending,UserName}) end, GamesToRemove),
                                      PidCommand!remove_ok,
                                      lists:map(fun(X) -> {pid_matchadm,X}!{remove_refresh,NewGames} end, nodes()),
                                      match_adm(NewGames);
    {solicite_list,PidCommand} -> PidCommand!{list,Games}
  end,
  match_adm(Games).

% A match has two instances: match represents the game in a 'lobby' state, waiting for
% someone to join. When a player 2 is joined, match_initialized is called  and keeps administrating the plays
match(Player1,Player2,Spects,MatchName) ->
  case Player2 of
    none -> receive
  	          {spect,SpectUser}  -> case lists:filter(fun(X) -> SpectUser == X end, Spects) of
                                      [] -> match(Player1,Player2,Spects++[SpectUser],MatchName);
                                       _ -> match(Player1,Player2,Spects,MatchName)
                                    end;
              {movement,_,_,UserName} -> global:send(UserName,not_start),
                                         match(Player1, Player2, Spects, MatchName);
  	          {join,UserName} -> global:send(Player1,{turn, MatchName}),
                                 match_initialized(Player1,UserName,true,"---------",Spects,MatchName);
              {ending,UserName} -> global:send(UserName,you_end_game);
              kill -> ok
            end
  end.

match_initialized(Player1,Player2,Turn,Board,Spects,MatchName) ->
  case Turn of
    % If it is player 1 turn
    true -> receive
              {movement,X,Y,User} -> if User == Player1 ->
                                          case lists:nth((3*(X-1)+Y),Board) of
                                            45 -> NewBoard = replace((3*(X-1)+Y),Board,"X"),
                                                  global:send(Player1,{update,NewBoard,MatchName}),
                                                  global:send(Player2,{update,NewBoard,MatchName}),
                                                  lists:map(fun(S) -> global:send(S,{update,NewBoard,MatchName}) end,Spects),
                                                  case someoneWon(NewBoard) of
                                                    true -> global:send(Player1,{victory, Player1, MatchName}),
                                                            global:send(Player2,{victory, Player1, MatchName}),
                                                            lists:map(fun(S) -> global:send(S,{victory, Player1, MatchName}) end,Spects),
                                                            lists:map(fun(N) -> {pid_matchadm,N}!{end_refresh,MatchName} end, nodes()),
                                                            pid_matchadm!{end_refresh, MatchName};
                                                    false -> case is_it_draw(NewBoard) of
                                                               false -> global:send(Player2,{turn,MatchName}),
                                                                        match_initialized(Player1,Player2,false,NewBoard,Spects,MatchName);
                                                               true  -> global:send(Player1,{draw, MatchName}),
                                                                        global:send(Player2,{draw, MatchName}),
                                                                        lists:map(fun(S) -> global:send(S,{draw, MatchName}) end,Spects),
                                                                        lists:map(fun(N) -> {pid_matchadm,N}!{end_refresh,MatchName} end,nodes()),
                                                                        pid_matchadm!{end_refresh, MatchName}
                                                             end
                                                  end;
                                            _  -> global:send(Player1,bad_index),
                                                  match_initialized(Player1,Player2,Turn,Board,Spects,MatchName)
                                          end;
                                        true -> global:send(User,no_valid_turn),
                                                match_initialized(Player1,Player2,Turn,Board,Spects,MatchName)
                                     end;
  	          {spect,SpectUser}  -> case lists:filter(fun(X) -> SpectUser == X end, Spects) of
                                      [] -> match_initialized(Player1,Player2, Turn, Board, Spects++[SpectUser],MatchName);
                                       _ -> match_initialized(Player1,Player2, Turn, Board, Spects,MatchName)
                                    end;
              {end_spect,SpectUser} -> match_initialized(Player1,Player2,Turn,Board,lists:filter(fun(X) -> SpectUser /= X end,Spects),MatchName);
              {ending,User} -> global:send(User,you_end_game),
                               if
                                 User == Player1 -> global:send(Player2,{opponent_end_game,User,MatchName});
                                 true -> global:send(Player1,{opponent_end_game,User,MatchName})
                               end,
                               lists:map(fun(S) -> global:send(S,{end_spect,User,MatchName}) end,Spects)
            end;
    % If it is player 2 turn
    false -> receive
               {movement,X,Y,User} -> if User == Player2 ->
                                           case lists:nth((3*(X-1)+Y),Board) of
                                             45 -> NewBoard = replace((3*(X-1)+Y),Board,"O"),
                                                   global:send(Player1,{update,NewBoard,MatchName}),
                                                   global:send(Player2,{update,NewBoard,MatchName}),
                                                   lists:map(fun(S) -> global:send(S,{update,NewBoard,MatchName}) end,Spects),
                                                   case someoneWon(NewBoard) of
                                                     true -> global:send(Player1,{victory, Player2, MatchName}),
                                                             global:send(Player2,{victory, Player2, MatchName}),
                                                             lists:map(fun(S) -> global:send(S,{victory, Player2, MatchName}) end,Spects),
                                                             lists:map(fun(N) -> {pid_matchadm,N}!{end_refresh,MatchName} end, nodes()),
                                                             pid_matchadm!{end_refresh, MatchName};
                                                     false -> case is_it_draw(NewBoard) of
                                                                false -> global:send(Player1,{turn,MatchName}),
                                                                         match_initialized(Player1,Player2,true,NewBoard,Spects,MatchName);
                                                                true  -> global:send(Player1,{draw, MatchName}),
                                                                         global:send(Player2,{draw, MatchName}),
                                                                         lists:map(fun(S) -> global:send(S,{draw, MatchName}) end,Spects),
                                                                         lists:map(fun(N) -> {pid_matchadm,N}!{end_refresh,MatchName} end,nodes()),
                                                                         pid_matchadm!{end_refresh, MatchName}
                                                              end
                                                   end;
                                             _  -> global:send(Player2,bad_index),
                                                   match_initialized(Player1,Player2,Turn,Board,Spects,MatchName)
                                           end;
                                         true -> global:send(User,no_valid_turn),
                                                 match_initialized(Player1,Player2,Turn,Board,Spects,MatchName)
                                      end;
               {ending,User} -> global:send(User,you_end_game),
                                if
                                  User == Player1 -> global:send(Player2,{opponent_end_game,User, MatchName});
                                  true -> global:send(Player1,{opponent_end_game,User, MatchName})
                                end,
                                lists:map(fun(S) -> global:send(S,{end_spect,User,MatchName}) end,Spects);
               {end_spect,SpectUser} -> match_initialized(Player1,Player2,Turn,Board,lists:filter(fun(X) -> SpectUser /= X end,Spects),MatchName);
  	           {spect,SpectUser}  -> case lists:filter(fun(X) -> SpectUser == X end, Spects) of
                                       [] -> match_initialized(Player1,Player2, Turn, Board, Spects++[SpectUser],MatchName);
                                        _ -> match_initialized(Player1,Player2, Turn, Board, Spects,MatchName)
                                     end
             end
  end.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%




%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Auxiliar functions
replace(N,List,Token) ->
  case N of
  	1 -> Token++lists:nthtail(1,List);
  	_ -> change(lists:nth(1,List))++replace(N-1,lists:nthtail(1,List),Token)
  end.

% Blame Erlang for this
change(X) ->
 case X of
   45  -> "-";
   88  -> "X";
   79  -> "O"
 end.

% Update a game from the gamelist in match_adm
update(Game,GameName,UserName) ->
  case Game of
    {GN,P1,P2} -> if GN == GameName -> {GN,P1,UserName};
                     true -> {GN,P1,P2}
                  end
  end.

is_movement_allowed(X,Y) ->
  (X>0) and (X<4) and (Y>0) and (Y<4).

atom_to_integer(Num) ->
  case catch list_to_integer(atom_to_list(Num)) of
    % If list_to_integer returns an error, we return a number out of range
    % that will be detected by match_adm
    {'EXIT', _} -> 5;

    % Otherwise, we return the number
    X -> X
  end.

%% Printing help
show_help() ->
        io_lib:format("~nCON <usuario>         -- conectarse al servidor con nombre <username>~n",[])++
        io_lib:format("LSG                   -- ver la lista de partidas~n",[])++
        io_lib:format("BYE                   -- desconectarse del servidor~n",[])++
        io_lib:format("NEW <sala>            -- crear una sala con nombre <sala>~n",[])++
        io_lib:format("SAY <usuario> <msj>   -- enviar un mensaje <msj> a <usuario>~n",[])++
        io_lib:format("ACC <sala>            -- acceder a la sala <sala> para jugar~n",[])++
        io_lib:format("PLA <sala> <x> <y>    -- realizar una jugada en la sala match en la posicion (x,y)~n",[])++
        io_lib:format("PLA <sala> END        -- abandonar la sala <sala> como jugador~n",[])++
        io_lib:format("OBS <sala>            -- unirse como espectador a la sala <sala>~n",[])++
        io_lib:format("LEA <sala>            -- dejar de observar la sala <sala>~n",[])++
        io_lib:format("HELP                  -- mostrar este menu~n~n",[]).

%% Used for printing the match when receiving LSG command
match_print(G) ->
 case G of
   {GameName,P1,none} -> io_lib:format("Partida: ~p, creador de la sala: ~p, estado: esperando contrincante~n",[GameName,P1]);
   {GameName,P1,P2} -> io_lib:format("Partida ~p, creador de la sala: ~p, estado: en curso - ~p vs ~p~n",[GameName,P1,P1,P2])
 end.

%% Checks if it is a draw
is_it_draw(Board) ->
  case lists:filter(fun(X) -> X==45 end, Board) of
    [] -> true;
     _ -> false
  end.

%% Checks if someone won the game in the most primitive way
someoneWon(Board) ->
  rowWin(Board) or columnWin(Board) or diagWin(Board).

rowWin(Board) ->
  ((lists:nth(1,Board) == lists:nth(2,Board)) and (lists:nth(2,Board) == lists:nth(3,Board)) and (lists:nth(1,Board) /= 45)) or
  ((lists:nth(4,Board) == lists:nth(5,Board)) and (lists:nth(5,Board) == lists:nth(6,Board)) and (lists:nth(4,Board) /= 45)) or
  ((lists:nth(7,Board) == lists:nth(8,Board)) and (lists:nth(8,Board) == lists:nth(9,Board)) and (lists:nth(7,Board) /= 45)).

columnWin(Board) ->
  ((lists:nth(1,Board) == lists:nth(4,Board)) and (lists:nth(4,Board) == lists:nth(7,Board)) and (lists:nth(1,Board) /= 45)) or
  ((lists:nth(2,Board) == lists:nth(5,Board)) and (lists:nth(5,Board) == lists:nth(8,Board)) and (lists:nth(2,Board) /= 45)) or
  ((lists:nth(3,Board) == lists:nth(6,Board)) and (lists:nth(6,Board) == lists:nth(9,Board)) and (lists:nth(3,Board) /= 45)).

diagWin(Board) ->
  ((lists:nth(1,Board) == lists:nth(5,Board)) and (lists:nth(5,Board) == lists:nth(9,Board)) and (lists:nth(1,Board) /= 45)) or
  ((lists:nth(7,Board) == lists:nth(5,Board)) and (lists:nth(5,Board) == lists:nth(3,Board)) and (lists:nth(7,Board) /= 45)).

is_in(UserName,Games) ->
  length(lists:filter(fun({P1,P2,_,_}) -> (P1 == UserName) or (P2 == UserName) end,Games)) == 1.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
