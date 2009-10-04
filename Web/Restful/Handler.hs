{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
---------------------------------------------------------
--
-- Module        : Web.Restful.Handler
-- Copyright     : Michael Snoyman
-- License       : BSD3
--
-- Maintainer    : Michael Snoyman <michael@snoyman.com>
-- Stability     : unstable
-- Portability   : portable
--
-- Define Handler stuff.
--
---------------------------------------------------------
module Web.Restful.Handler
    ( -- * Handler monad
      HandlerT
    , HandlerIO
    , Handler
    , runHandler
    , liftIO
      -- * Special handlers
    , redirect
    , notFound
      -- * Setting headers
    , addCookie
    , deleteCookie
    , header
    ) where

import Web.Restful.Request
import Web.Restful.Response

import Control.Monad.Trans
import Control.Monad (liftM, ap)
import Control.Applicative

import Data.Maybe (fromJust)
import qualified Data.ByteString.Lazy as B
import qualified Hack

------ Handler monad
newtype HandlerT m a =
    HandlerT (RawRequest -> m (Either ErrorResult a, [Header]))
type HandlerIO = HandlerT IO
type Handler = HandlerIO Reps

runHandler :: (ErrorResult -> Reps)
            -> (ContentType -> B.ByteString -> IO B.ByteString)
            -> [ContentType]
            -> Handler
            -> RawRequest
            -> IO Hack.Response
runHandler eh wrapper ctypesAll (HandlerT inside) rr = do
    (x, headers') <- inside rr
    let extraHeaders =
            case x of
                Left r -> getHeaders r
                Right _ -> []
    headers <- mapM toPair (headers' ++ extraHeaders)
    let outReps = either (reps . eh) reps x
    let statusCode =
            case x of
                Left r -> getStatus r
                Right _ -> 200
    (ctype, selectedRep) <- chooseRep outReps ctypesAll
    finalRep <- wrapper ctype selectedRep
    let headers'' = ("Content-Type", ctype) : headers
    return $! Hack.Response statusCode headers'' finalRep

chooseRep :: Monad m
          => [(ContentType, B.ByteString)]
          -> [ContentType]
          -> m (ContentType, B.ByteString)
chooseRep rs cs
  | length rs == 0 = fail "All reps must have at least one value"
  | otherwise = do
    let availCs = map fst rs
    case filter (`elem` availCs) cs of
        [] -> return $ head rs
        [ctype] -> return (ctype, fromJust $ lookup ctype rs)
        _ -> fail "Overlapping representations"

instance MonadTrans HandlerT where
    lift ma = HandlerT $ const $ do
        a <- ma
        return (Right a, [])

instance MonadIO HandlerIO where
    liftIO = lift

instance Monad m => Functor (HandlerT m) where
    fmap = liftM

instance Monad m => Monad (HandlerT m) where
    return = lift . return
    fail s = HandlerT (const $ return (Left $ InternalError s, []))
    (HandlerT mx) >>= f = HandlerT $ \rr -> do
        (x, hs1) <- mx rr
        case x of
            Left x' -> return (Left x', hs1)
            Right a -> do
                let (HandlerT b') = f a
                (b, hs2) <- b' rr
                return (b, hs1 ++ hs2)

instance Monad m => Applicative (HandlerT m) where
    pure = return
    (<*>) = ap

instance Monad m => MonadRequestReader (HandlerT m) where
    askRawRequest = HandlerT $ \rr -> return (Right rr, [])
    invalidParam ptype name msg =
        errorResult $ InvalidArgs [(name ++ " (" ++ show ptype ++ ")", msg)]
    authRequired = errorResult PermissionDenied

------ Special handlers
errorResult :: Monad m => ErrorResult -> HandlerT m a
errorResult er = HandlerT (const $ return (Left er, []))

-- | Redirect to the given URL.
redirect :: Monad m => String -> HandlerT m a
redirect = errorResult . Redirect

-- | Return a 404 not found page. Also denotes no handler available.
notFound :: Monad m => HandlerT m a
notFound = errorResult NotFound

------- Headers
-- | Set the cookie on the client.
addCookie :: Monad m
          => Int -- ^ minutes to timeout
          -> String -- ^ key
          -> String -- ^ value
          -> HandlerT m ()
addCookie a b c = addHeader $ AddCookie a b c

-- | Unset the cookie on the client.
deleteCookie :: Monad m => String -> HandlerT m ()
deleteCookie = addHeader . DeleteCookie

-- | Set an arbitrary header on the client.
header :: Monad m => String -> String -> HandlerT m ()
header a b = addHeader $ Header a b

addHeader :: Monad m => Header -> HandlerT m ()
addHeader h = HandlerT (const $ return (Right (), [h]))
