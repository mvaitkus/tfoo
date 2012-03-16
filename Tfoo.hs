{-# LANGUAGE TypeFamilies, QuasiQuotes, MultiParamTypeClasses,
             TemplateHaskell, OverloadedStrings #-}
module Tfoo where
import Yesod
import Yesod.Static
import Control.Concurrent.Chan
import Data.Text as T
import Data.List as L
import Data.Maybe as M
import System.Random as R
import Control.Concurrent.MVar as V
import Control.Monad as MD
import Data.Monoid
import Blaze.ByteString.Builder.Char.Utf8 (fromString)
import Network.Wai.EventSource (ServerEvent (..), eventSourceApp)
import Text.Hamlet (hamletFile)
import Text.Lucius (luciusFile)

replace :: Int -> a -> [a] -> [a]
replace index element list = (L.take index list) ++ [element] ++ (L.drop (index+1) list)

findList :: (Eq a) => [a] -> [a] -> Bool
findList sequence list = sequence `elem` L.concat (L.map L.inits (L.tails list))

type Matrix a = [[a]]

replace' :: Int -> Int -> a -> Matrix a -> Matrix a
replace' x y element matrix = Tfoo.replace x (Tfoo.replace y element (matrix !! x)) matrix

diagonal :: Matrix a -> [a]
diagonal m = L.zipWith (!!) m [0..]

diagonals :: Matrix a -> [[a]]
diagonals matrix =
  let tails' = L.tail . L.tails
      diagonalsNW m = L.map diagonal ([m] ++ tails' m ++ tails' (L.transpose m))
  in diagonalsNW matrix ++ diagonalsNW (L.map L.reverse matrix)

data Mark = O | X deriving (Eq, Show)
type Cell = Maybe Mark

type Pattern   = [Cell]
type Board     = Matrix Cell

generateBoard :: Int -> Board
generateBoard size = [ [Nothing | x <- [1..size]] | y <- [1..size]]

patterns :: Board -> [Pattern]
patterns board = board ++ (L.transpose board) ++ (diagonals board)

winner :: Board -> Maybe Mark
winner board
  | L.any (findList [Just O, Just O, Just O, Just O, Just O]) (patterns board) = Just O
  | L.any (findList [Just X, Just X, Just X, Just X, Just X]) (patterns board) = Just X
  | otherwise = Nothing

type Player = String
data Game = Game {
  playerX :: Maybe Player,
  playerO :: Maybe Player,
  channel :: Chan ServerEvent,
  board   :: Board
}

setPlayer :: Game -> Mark -> Player -> Game
setPlayer game O playerId = game { playerO = Just playerId }
setPlayer game X playerId = game { playerX = Just playerId }

getCell :: Board -> Int -> Int -> Cell
getCell board x y = (((board) !! x) !! y)

whoseTurn :: Game -> Maybe Player
whoseTurn g = if nextMark (board g) == O then playerO g else playerX g

nextMark :: Board -> Mark
nextMark board = if (count X) <= (count O) then X else O where
  count mark = L.length $ L.filter (Just mark == ) $ L.concat board


data Tfoo = Tfoo {
    seed       :: Int,
    games      :: MVar [IO Game],
    nextGameId :: MVar Int,
    tfooStatic :: Static
  }

mkYesod "Tfoo" [parseRoutes|
/                           HomeR GET
/games                      GamesR POST
/games/#Int                 GameR GET
/games/#Int/join/o          PlayerOR POST
/games/#Int/join/x          PlayerXR POST
/games/#Int/mark/#Int/#Int  MarkR POST
/games/#Int/listen          ChannelR GET
/static                     StaticR Static tfooStatic
|]

instance Yesod Tfoo

getHomeR :: Handler RepHtml
getHomeR = do
  tfoo <- getYesod
  defaultLayout $ do
    addStylesheet $ StaticR $ StaticRoute ["styles", "tfoo.css"] []
    [whamlet|
      <div .landing-page>
        <h1> TFOO!
        <h2> Take Five online, obviously.
        <div>
          An implementation of Take Five game (wikipedia) that utilizes Haskell,
          Yesod (Haskell web framework) and EventSource (http://caniuse.com/eventsource).
        <div>
          <form method=post action=@{GamesR}>
            <input type=submit value="START GAME">
        <div> Read a blog post:
        <div> View source on GitHub:
    |]

postGamesR :: Handler RepHtml
postGamesR = do
    tfoo <- getYesod
    id   <- liftIO $ newGameId tfoo
    redirect $ GameR id
  where -- Increment Tfoo's Game counter and return id of the next new Game.
        newGameId :: Tfoo -> IO Int
        newGameId tfoo = modifyMVar (nextGameId tfoo) incrementMVar

        incrementMVar :: Int -> IO (Int, Int)
        incrementMVar value = return (value+1, value)

getGameR :: Int -> Handler RepHtml
getGameR id = let
    columns = [0..19]
    rows    = [0..19]
  in do
    game <- getGame id
    maybePlayers <- lookupSession "players"
    tfoo <- getYesod
    defaultLayout $ do
      toWidgetHead [julius|
        var post = function(url){
          var xhr = new XMLHttpRequest();
          xhr.open("POST", url);
          xhr.send(null);
        };
        $(document).ready(function() {
          var src = new EventSource("@{ChannelR id}");
          src.onmessage = function(input) {
            console.log(input.data);
            var message = JSON.parse(input.data);
            if (message.id == "player-new"){
              $("#no_player_"+message.side).replaceWith("<div>Joined</div>");
            } else if (message.id == "mark-new") {
              var markId = "#cell_"+message.x+"_"+message.y;
              $(markId).replaceWith(
                "<div id='"+markId+"' class='mark-"+message.mark+"'></div>"
              );
            } else if (message.id == "alert") {
              $("#messages").prepend(
                "<div class='message'>"+message.content+"</div>"
              );
            }
          };
          $('.mark-new').each(function(index, element){
            $(element).click(function(){
              var x = $(element).attr('data-x');
              var y = $(element).attr('data-y');
              post('#{show id}/mark/' + x + '/' + y);
            });
          });
        });
      |]
      addStylesheet $ StaticR $ StaticRoute ["styles", "tfoo.css"] []
      addScript $ StaticR $ StaticRoute ["scripts","jquery-1.7.1.min.js"] []
      [whamlet|
        <div .players>
          <div #player_x>
            <div .player-description>
              Cross:
            $maybe player <- (playerX game)
              <div #joined >
                Joined
                $maybe you <- maybePlayers
                  $if elem player (L.words $ T.unpack you)
                    (You)
                  $else
            $nothing
              <div .player-join #no_player_X >
                <form method=post action=@{PlayerXR id}>
                  <input value="Join as X" type=submit>
          <div #player_o>
            <div .player-description>
              Circle:
            $maybe player <- (playerO game)
              <div #joined >
                Joined
                $maybe you <- maybePlayers
                  $if elem player (L.words $ T.unpack you)
                    (You)
                  $else
            $nothing
              <div .player-join #no_player_O >
                <form method=post action=@{PlayerOR id}>
                  <input value="Join as O" type=submit>
        <div #messages>
        <table #board>
          $forall column <- columns
            <tr>
              $forall row <- rows
                <td>
                  $maybe mark <- getCell (board game) row column
                    <div #cell_#{row}_#{column} .mark-#{show mark} data-x=#{row} data-y=#{column}>
                  $nothing
                    <div #cell_#{row}_#{column} ."mark-new" data-x=#{row} data-y=#{column}>
      |]

postMarkR :: Int -> Int -> Int -> Handler ()
postMarkR id x y = do
    game               <- getGame id
    whoseTurn'         <- return $ whoseTurn game
    board'             <- return $ board game
    userAuthorizations <- do
      authorizations <- lookupSession "players"
      return $ fmap (L.words . T.unpack) authorizations

    -- The target cell has to be empty.
    require $ (getCell (board game) x y) == Nothing
    -- User has to be authorized to make this move
    require $ fromMaybe False (MD.liftM2 elem whoseTurn' userAuthorizations)
    -- The game has to be still in progress
    require $ (winner board') == Nothing

    updateGame id $ game {board = replace' x y (Just $ nextMark board') board'}

    broadcast id "mark-new" [
        ("x", show x), ("y", show y), ("mark", show (nextMark board'))
      ]

    broadcastGameState id

  where require result = if result == False
          then permissionDenied "Permission Denied"
          else return ()
        elem' x y = (elem . L.words . T.unpack)
        userAuthorizations' = L.words . T.unpack

broadcastGameState :: Int -> Handler ()
broadcastGameState id = do
    game  <- getGame id
    board' <- return $ board game
    maybe (notifyNextPlayer board') announceWinner (winner board')
  where
    notifyNextPlayer board =
      broadcast id "alert" [("content", (show $ nextMark board)++"'s turn")]
    announceWinner mark =
      broadcast id "alert" [("winner", "Game won: "++(show mark))]


postPlayerOR :: Int -> Handler RepHtml
postPlayerOR id = do
  game <- getGame id
  if (playerO game) == Nothing
    then do
      joinGame id O
      broadcast id "player-new" [("side", "O")]
      return ()
    else return ()
  redirect $ GameR id

postPlayerXR :: Int -> Handler RepHtml
postPlayerXR id = do
  game <- getGame id
  broadcast id "debug" [("message", "Invoked postPlayerXR")]
  if (playerX game) == Nothing
    then do
      joinGame id X
      broadcast id "player-new" [("side", "X")]
      return ()
    else return ()
  redirect $ GameR id

getChannelR :: Int -> Handler ()
getChannelR id = do
  game <- getGame id
  chan <- liftIO $ dupChan $ channel game
  req  <- waiRequest
  res  <- lift $ eventSourceApp chan req
  updateGame id game
  sendWaiResponse res

broadcast :: Int -> String -> [(String, String)] -> Handler ()
broadcast gameId messageId pairs = do
  game <- getGame gameId
  liftIO $ writeChan (channel game) $ serverEvent $ return $ fromString message
  where message = "{"++(stringifiedPairs $ ("id",messageId):pairs)++"}"
        stringifiedPairs pairs = L.intercalate ", " $ L.map stringifyPair pairs
        stringifyPair p = "\""++(fst p) ++ "\": \"" ++ (snd p) ++ "\""
        serverEvent = ServerEvent Nothing Nothing

joinGame :: Int -> Mark -> Handler ()
joinGame id mark =
  do
    game <- getGame id
    tfoo <- getYesod
    appendSession' "players" $ T.pack (playerId tfoo)
    updateGame id $ setPlayer game mark (playerId tfoo)
    return ()
  where
    playerId tfoo = (show $ seed tfoo) ++ (show id) ++ (show mark)

-- Appends the given value to the session key.
appendSession :: Text -> Text -> Handler ()
appendSession name value = do
  initial <- lookupSession name
  setSession name $ fromJust $ initial `mappend` Just value

-- Appends the given value to the session key, inserts space before the value.
appendSession' :: Text -> Text -> Handler ()
appendSession' name value = appendSession name (T.pack " " `mappend` value)

getGame :: Int -> Handler Game
getGame id = do
  tfoo <- getYesod
  maxId <- liftIO $ readMVar $ nextGameId tfoo
  list  <- liftIO $ readMVar $ games tfoo
  if id < maxId
    then (liftIO $ (list) !! id) >>= (\game -> return game)
    else notFound

-- todo: refactor
updateGame :: Int -> Game -> Handler ()
updateGame id game = do
  tfoo <- getYesod
  liftIO $ modifyMVar (games tfoo) (\games ->
      return (replace id (return game) games, games)
    )
  return ()

createGame :: IO Game
createGame = do
  channel <- newChan
  return Game {
    playerO = Nothing,
    playerX = Nothing,
    channel = channel,
    board   = generateBoard 20
  }

gameStream :: [IO Game]
gameStream = repeat createGame

main :: IO ()
main = do
  nextGameId <- newMVar 1
  games <- newMVar gameStream
  seedP <- liftIO $ getStdGen >>= (\x -> return $ next x)
  static' <- static "static"
  warpDebug 3100 (Tfoo (fst seedP) games nextGameId static')
