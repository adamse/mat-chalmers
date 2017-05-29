-- |

module M.Wijkanders (getWijkanders) where

import qualified Data.Text.Lazy as T
import           GHC.Exts
import           Text.HTML.TagSoup

import           M.Internal hiding (menu, date)
import           Util
import Data.Maybe (catMaybes)

getWijkanders :: Int -> IO (Maybe Restaurant)
getWijkanders weekday = do
  ts <- getTags
  return $ do
    tags <- ts
    dayt <- getDay weekday tags
    mst <- getMenus dayt
    let ms = catMaybes $ map mkMenu mst
    return (mkRestaurant ms)

getTags :: IO (Maybe ([Tag T.Text]))
getTags = do
  text <- handle' (get "http://www.wijkanders.se/restaurangen/")
  return (text >>= return . parseTags)

getDay :: Int -> [Tag T.Text] -> Maybe [Tag T.Text]
getDay weekday tags = do
  post <- safeHead $ partitions (~== "<div class='post-content'>") tags
  let ps = partitions (~== "<p>") post
  let days = drop 4 ps
  safeIdx days weekday

getMenus :: [Tag T.Text] -> Maybe [[Tag T.Text]]
getMenus day = do
  let ms = drop 1 $ partitions (~== "<strong>") day
  return ms

mkMenu :: [Tag T.Text] -> Maybe Menu
mkMenu m = do
  what <- safeIdx m 1
  food <- safeIdx m 3
  let lunch = T.toTitle . T.dropEnd 1 . text $ [what]
  if T.null lunch
    then Nothing
    else return $ Menu lunch (text [food])

text = T.strip . innerText

mkRestaurant ms =
  Restaurant
  (fromString "Wijkanders")
  (fromString "http://www.wijkanders.se/restaurangen/")
  ms