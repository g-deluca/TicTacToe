-module(server).
-compile(export_all).

% Start a server
start(Name, Port) ->
  net_kernel:start([Name, shortnames]),
  spawn(?MODULE, server, [Port]).

server(Port) ->
  {ok, LSock} = gen_tcp:listen(Port,[{packet,0},{active,false}]),

  PidBalance = spawn(?MODULE, pbalance, [statistics(total_active_tasks),node()]),
  register(pid_balance, PidBalance),

  PidMatch = spawn(?MODULE, match_adm, [[]]),
  register(pid_matchadm, PidMatch),

  spawn(?MODULE, stat, []),
  dispatcher(LSock, 1).

% Dispatcher accepts the connections and spawns a psocket for each client
dispatcher(LSock, Cont) ->
  % Accept the connection
  {ok, CSock} = gen_tcp:accept(LSock),

% Start processes that will handle the connection with client
  NameListener = list_to_atom("listener"++integer_to_list(Cont)),
  PidListener = spawn(?MODULE, listener, [CSock]),
  register(NameListener, PidListener),

  NameSocket = list_to_atom("socket"++integer_to_list(Cont)),
  PidSocket = spawn(?MODULE, psocket, [CSock, none, true, NameSocket, NameListener]),
  register(NameSocket, PidSocket),

  dispatcher(LSock, Cont+1).

% The processes pbalance and stat handle the balance of the nodes
pbalance(TotalTasks, Node) ->
  receive
    {stat, NewTotal, NewNode} -> if NewTotal =< TotalTasks -> pbalance(NewTotal, NewNode);
                                    true                   -> pbalance(TotalTasks, Node)
                                 end;
    {connect, Pid} -> Pid!{spawn, Node},
                      pbalance(TotalTasks, Node)
  end.

stat() ->
  TotalTasks = statistics(total_active_tasks),

% We inform all nodes of the current status
  pid_balance!{stat, TotalTasks, node()},
  lists:map(fun(X) -> {pid_balance,X}!{stat, TotalTasks,node()} end, nodes()),

  receive after 2000 -> ok end,
  stat().

psocket(CSock, UserName, Flag, Socket, Listener) ->
  case gen_tcp:recv(CSock,0) of
    {ok, Binary} ->
      pid_balance!{connect, self()},
      receive
        {spawn, Node} -> spawn(Node, server, pcommand, [Binary, UserName, Flag, node(), Socket, Listener])
      end,
      receive
        {log, User} -> gen_tcp:send(CSock, "LOG " ++ atom_to_list(User)),
                       psocket(CSock, User, false, Socket, Listener);
        {games, ListGames} -> gen_tcp:send(CSock,"GAMES "++ListGames);
        log_fail -> gen_tcp:send(CSock, "LOG_FAIL ");
        already_log -> gen_tcp:send(CSock,"ALREADY_LOG "++atom_to_list(UserName));
        not_log -> gen_tcp:send(CSock,"NOT_LOG ");
        log_out -> gen_tcp:send(CSock,"EXIT "),
                   exit(normal);
        match_created -> gen_tcp:send(CSock,"GAME ");
        already_registered -> gen_tcp:send(CSock,"ALREADY_REGISTERED ");
        joined -> gen_tcp:send(CSock,"JOIN ");
        well_delivered -> gen_tcp:send(CSock,"WELL_DELIVERED ");
        spect_ok  -> gen_tcp:send(CSock,"SPECT_OK ");
        no_valid_game -> gen_tcp:send(CSock,"NO_VALID_GAME ");
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
    {opponent_end_game,UserName} -> gen_tcp:send(CSock,"OPPONENT_END_GAME "++atom_to_list(UserName));
    {say,UserName,Msg} -> gen_tcp:send(CSock,"SAY "++atom_to_list(UserName)++" "++Msg);
    {end_spect,UserName,Game} -> gen_tcp:send(CSock,"END_SPECT "++atom_to_list(UserName)++" "++atom_to_list(Game));
    turn -> gen_tcp:send(CSock,"TURN ");
    not_start -> gen_tcp:send(CSock,"NOT_START ");
    no_valid -> gen_tcp:send(CSock,"NO_VALID ");
    you_end_game -> gen_tcp:send(CSock,"YOU_END_GAME ")
  end,

  receive after 1000 -> ok end,
  listener(CSock).

% This process will be globally registered, and will redirects the message to the listener of
% that client. It aims to simplify the internal communication.
user(Listener, ListenerNode) ->
  receive
    kill -> exit(normal);
    M -> {Listener, ListenerNode}!M
  end,
  user(Listener, ListenerNode).

% The pcommand procces will understand the client commands and take action
pcommand(Binary, UserName, Flag, Node, Socket, Listener) ->
  Input = lists:map(fun(X) -> list_to_atom(X) end, string:tokens(Binary," \n")),
  Args = length(Input),
  case Args of
    0 -> {Socket, Node}!no_args;
    _ -> Command = lists:nth(1, Input),
         case Flag of
           true -> case Command of
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
                             'BYE' -> global:send(UserName, kill),
                                      {Socket, Node}!log_out;
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
                                        joined -> {Socket, Node}!joined;
                                        no_valid_game -> {Socket, Node}!no_valid_game
                                      end;
                             'LEA' -> pid_matchadm!{end_spect, Arg1, UserName, self()},
                                      {Socket, Node}!end_spect_ok;
                             'OBS' -> pid_matchad!{spect, Arg1, UserName,self()},
                                      receive
                                        no_valid_game -> {Socket, Node}!no_valid_game;
                                        spect_ok -> {Socket, Node}!spect_ok
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
                              _   -> {Socket, Node}!incorrect
                           end;
                      4 -> Arg1 = lists:nth(2, Input),
                           Arg2 = lists:nth(3, Input),
                           Arg3 = lists:nth(4, Input),
                           case Command of
                             'PLA'-> pid_matchadm!{movement, Arg1, atom_to_integer(Arg2), atom_to_integer(Arg3), UserName, self()},
                                     receive
                                       well_delivered -> {Socket, Node}!well_delivered;
                                       no_valid_game -> {Socket, Node}!no_valid_game
                                     end;
                              _   -> {Socket, Node}!incorrect
                           end;
                      _ -> {Socket, Node}!incorrect
                    end
         end
  end.

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
                                                         _    -> PidCommand!no_valid_game
                                                       end
                                               end;
    {ending, MatchName, UserName, PidCommand} -> PossibleGame = lists:filter(fun({G,_,_}) -> MatchName == G end,Games),
                                                 case PossibleGame of
                                                   [] -> PidCommand!no_valid_game;
                                                   _  -> {G,P1,P2} = lists:nth(1,PossibleGame),
                                                         case (P1 == UserName) or (P2 == UserName) of
                                                           true -> global:send(G,{ending,UserName}),
                                                                   lists:map(fun(X) -> {matchadm,X}!{end_refresh,MatchName} end, nodes()),
                                                                   match_adm(lists:filter(fun ({X,_,_}) -> X /= MatchName end, Games)),
                                                                   PidCommand!well_delivered;
                                                           false -> PidCommand!not_allowed
                                                         end
                                                 end;
    {spect, MatchName, UserName, PidCommand} -> PossibleGame = lists:filter(fun({G,_,_}) -> MatchName == G end,Games),
                                                case PossibleGame of
                                                  [] -> PidCommand!no_valid_game;
                                                  _  -> {G,_,_} = lists:nth(1,PossibleGame),
                                                        global:send(G,{spect,UserName}),
                                                        PidCommand!spect_ok
                                                end;
    {end_spect, MatchName,UserName,PidCommand} -> PossibleGame = lists:filter(fun({G,_,_}) -> MatchName == G end,Games),
                                                  case PossibleGame of
                                                    [] -> PidCommand!no_valid_game;
                                                    _  -> {G,_,_} = lists:nth(1,PossibleGame),
                                                          global:send(G,{end_spect,UserName}),
                                                          PidCommand!end_spect
                                                  end;
    {refresh,NewGame} -> match_adm(Games++NewGame);
    {join_refresh,MatchName,UserName} -> match_adm(lists:map(fun(X) -> update(X,MatchName,UserName) end,Games));
    {end_refresh, MatchName} -> match_adm(lists:filter(fun ({G,_,_}) -> G /= MatchName end, Games));
    {movement,MatchName,X,Y,UserName,PidCommand} -> PossibleGame = lists:filter(fun({G,_,_}) -> MatchName == G end, Games),
                                                    case PossibleGame of
                                                      [] -> PidCommand!no_valid_game;
                                                       _ -> PidCommand!well_delivered,
                                                            global:send(MatchName,{movement,X,Y,UserName})
                                                    end;
    {solicite_list,PidCommand} -> PidCommand!{list,Games}
  end,
  match_adm(Games).

match(Player1,Player2,Spects,MatchName) ->
  case Player2 of
    none -> receive
  	          {spect,SpectUser}  -> match(Player1,Player2,Spects++[SpectUser],MatchName);
              {movement,_,_,UserName} -> global:send(UserName,not_start);
  	          {join,UserName} -> global:send(Player1,turn),
                                 match_initialized(Player1,UserName,true,"---------",Spects,MatchName);
              {ending,UserName} -> global:send(UserName,you_end_game);
              kill -> ok
  			    end
  end.

match_initialized(Player1,Player2,Turn,Board,Spects,MatchName) ->
  case Turn of
    % If it is player 1
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
                                                            lists:map(fun(S) -> global:send(S,{victory, Player1, MatchName}) end,Spects);

                                                    false -> global:send(Player2,turn),
  																                           match_initialized(Player1,Player2,false,NewBoard,Spects,MatchName)
                                                  end;
  																          _  -> global:send(Player1,no_valid),
                                                  match_initialized(Player1,Player2,Turn,Board,Spects,MatchName)
  										                   end;
  											                true -> global:send(User,no_valid),
                                                match_initialized(Player1,Player2,Turn,Board,Spects,MatchName)
                                     end;
  			    	{spect,SpectUser} -> match_initialized(Player1,Player2,Turn,Board,Spects++[SpectUser],MatchName);
              {end_spect,SpectUser} -> match_initialized(Player1,Player2,Turn,Board,lists:filter(fun(X) -> SpectUser /= X end,Spects),MatchName);
              {ending,User} -> global:send(User,you_end_game),
                               if
                                 User == Player1 -> global:send(Player2,{opponent_end_game,User});
                                 true -> global:send(Player1,{opponent_end_game,User})
                               end,
                               lists:map(fun(S) -> global:send(S,{end_spect,User,MatchName}) end,Spects)
            end;
  		false -> receive
  				       {movement,X,Y,User} -> if
  				                                User == Player2 ->
                                            case lists:nth((3*(X-1)+Y),Board) of
  								                            45 -> NewBoard = replace((3*(X-1)+Y),Board,"O"),
  																                  global:send(Player1,{update,NewBoard,MatchName}),
  																	                global:send(Player2,{update,NewBoard,MatchName}),
  																	                lists:map(fun(S) -> global:send(S,{update,NewBoard,MatchName}) end,Spects),
                                                    case someoneWon(NewBoard) of
  																                    true -> global:send(Player1,{victory, Player2, MatchName}),
  																	                          global:send(Player2,{victory, Player2, MatchName}),
  																	                          lists:map(fun(S) -> global:send(S,{victory, Player2, MatchName}) end,Spects);
                                                      false -> global:send(Player1,turn),
  																                             match_initialized(Player1,Player2,true,NewBoard,Spects,MatchName)
                                                    end;
  														           		  _  -> global:send(Player2,no_valid),
                                                    match_initialized(Player1,Player2,Turn,Board,Spects,MatchName)
  										                      end;
  											                  true -> global:send(User,no_valid),
                                                  match_initialized(Player1,Player2,Turn,Board,Spects,MatchName)
                                        end;
                  {ending,User} -> global:send(User,you_end_game),
                                   if
                                     User == Player1 -> global:send(Player2,{opponent_end_game,User});
                                     true -> global:send(Player1,{opponent_end_game,User})
                                   end,
                                   lists:map(fun(S) -> global:send(S,{end_spect,User,MatchName}) end,Spects);
                  {end_spect,SpectUser} -> match_initialized(Player1,Player2,Turn,Board,lists:filter(fun(X) -> SpectUser /= X end,Spects),MatchName);
  				        {spect,SpectUser} -> match_initialized(Player1,Player2,Turn,Board,Spects++[SpectUser],MatchName)
                end
  end.


%Auxiliar functions
replace(N,List,Token) ->
  case N of
  	1 -> Token++lists:nthtail(1,List);
  	_ -> change(lists:nth(1,List))++replace(N-1,lists:nthtail(1,List),Token)
 	end.

change(X) ->
 	case X of
 		45  -> "-";
 		88  -> "X";
 		79  -> "O"
 	end.

update(Game,GameName,UserName) ->
  case Game of
    {GN,P1,P2} -> if GN == GameName -> {GN,P1,UserName};
                     true -> {GN,P1,P2}
  		            end
  end.


atom_to_integer(Num) ->
  list_to_integer(atom_to_list(Num)).


match_print(G) ->
 	case G of
 		{GameName,P1,none} -> io_lib:format("La partida de ~p busca contricante, el nombre es ~p~n",[P1,GameName]);
 		{GameName,P1,P2} -> io_lib:format("La partida de ~p esta en curso. ~p VS ~p, el nombre es ~p~n",[P1,P1,P2,GameName])
 	end.

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