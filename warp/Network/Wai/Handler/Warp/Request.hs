{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}

module Network.Wai.Handler.Warp.Request where

import Control.Applicative
import Control.Monad (when)
import Control.Exception.Lifted (throwIO)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as B (unpack)
import qualified Data.ByteString.Unsafe as SU
import qualified Data.CaseInsensitive as CI
import qualified Data.IORef as I
import Data.Monoid (mempty)
import Data.Word (Word8)
import qualified Network.HTTP.Types as H
import Network.Socket (SockAddr)
import Network.Wai
import Network.Wai.Internal
import Network.Wai.Handler.Warp.Conduit
import Network.Wai.Handler.Warp.ReadInt
import Network.Wai.Handler.Warp.Types
import Prelude hiding (lines)
import qualified Network.Wai.Handler.Warp.Timeout as Timeout

-- FIXME come up with good values here
maxTotalHeaderLength :: Int
maxTotalHeaderLength = 50 * 1024

parseRequest
             :: Connection
             -> Timeout.Handle
             -> SockAddr
             -> Source
             -> IO Request
parseRequest conn timeoutHandle remoteHost' src = do
    headers' <- takeHeaders src
    parseRequest' conn timeoutHandle headers' remoteHost' src

handleExpect :: Connection
             -> H.HttpVersion
             -> ([H.Header] -> [H.Header])
             -> [H.Header]
             -> IO [H.Header]
handleExpect _ _ front [] = return $ front []
handleExpect conn hv front (("expect", "100-continue"):rest) = do
    connSendAll conn $
        if hv == H.http11
            then "HTTP/1.1 100 Continue\r\n\r\n"
            else "HTTP/1.0 100 Continue\r\n\r\n"
    return $ front rest
handleExpect conn hv front (x:xs) = handleExpect conn hv (front . (x:)) xs

-- | Parse a set of header lines and body into a 'Request'.
parseRequest' :: Connection
              -> Timeout.Handle
              -> [ByteString]
              -> SockAddr
              -> Source
              -> IO Request
parseRequest' _ _ [] _ _ = throwIO $ NotEnoughLines []
parseRequest' conn timeoutHandle (firstLine:otherLines) remoteHost' src = do
    (method, rpath', gets, httpversion) <- parseFirst firstLine
    let rpath
            | S.null rpath' = "/"
            | "http://" `S.isPrefixOf` rpath' = snd $ S.breakByte 47 $ S.drop 7 rpath'
            | otherwise = rpath'
    heads <- liftIO
           $ handleExpect conn httpversion id
             (map parseHeaderNoAttr otherLines)
    let len0 =
            case lookup H.hContentLength heads of
                Nothing -> 0
                Just bs -> readInt bs
    let chunked = maybe False ((== "chunked") . CI.foldCase)
                  $ lookup hTransferEncoding heads
    rbody <-
        if chunked
          then do
            ref <- I.newIORef NeedLen
            return $ chunkedSource src ref
          else do
            icount <- I.newIORef len0
            return $ ibsIsolate $ IsolatedBSSource src icount

    return Request
            { requestMethod = method
            , httpVersion = httpversion
            , pathInfo = H.decodePathSegments rpath
            , rawPathInfo = rpath
            , rawQueryString = gets
            , queryString = H.parseQuery gets
            , requestHeaders = heads
            , isSecure = False
            , remoteHost = remoteHost'
            , requestBody = do
                error "FIXME requestBody"
                {-
                -- Timeout handling was paused after receiving the full request
                -- headers. Now we need to resume it to avoid a slowloris
                -- attack during request body sending.
                liftIO $ Timeout.resume timeoutHandle
                -- As soon as we finish receiving the request body, whether
                -- because the application is not interested in more bytes, or
                -- because there is no more data available, pause the timeout
                -- handler again.
                addCleanup (const $ liftIO $ Timeout.pause timeoutHandle) rbody
                -}
            , vault = mempty
            , requestBodyLength =
                if chunked
                    then ChunkedBody
                    else KnownLength $ fromIntegral len0
            }

{-# INLINE takeUntil #-}
takeUntil :: Word8 -> ByteString -> ByteString
takeUntil c bs =
    case S.elemIndex c bs of
       Just !idx -> SU.unsafeTake idx bs
       Nothing -> bs

{-# INLINE parseFirst #-} -- FIXME is this inline necessary? the function is only called from one place and not exported
parseFirst :: ByteString
           -> IO (ByteString, ByteString, ByteString, H.HttpVersion)
parseFirst s =
    case filter (not . S.null) $ S.splitWith (\c -> c == 32 || c == 9) s of  -- ' '
        (method:query:http'') -> do
            let http' = S.concat http''
                (hfirst, hsecond) = S.splitAt 5 http'
            if hfirst == "HTTP/"
               then let (rpath, qstring) = S.breakByte 63 query  -- '?'
                        hv =
                            case hsecond of
                                "1.1" -> H.http11
                                _ -> H.http10
                    in return (method, rpath, qstring, hv)
               else throwIO NonHttp
        _ -> throwIO $ BadFirstLine $ B.unpack s

parseHeaderNoAttr :: ByteString -> H.Header
parseHeaderNoAttr s =
    let (k, rest) = S.breakByte 58 s -- ':'
        rest' = S.dropWhile (\c -> c == 32 || c == 9) $ S.drop 1 rest
     in (CI.mk k, rest')

type BSEndo = ByteString -> ByteString
type BSEndoList = [ByteString] -> [ByteString]

data THStatus = THStatus
    {-# UNPACK #-} !Int -- running total byte count
    BSEndoList -- previously parsed lines
    BSEndo -- bytestrings to be prepended

{-# INLINE takeHeaders #-}
takeHeaders :: Source -> IO [ByteString]
takeHeaders src = do
    bs <- readSource src
    if S.null bs
        then throwIO ConnectionClosedByPeer
        else push src (THStatus 0 id id) bs

close :: IO a
close = throwIO IncompleteHeaders

push :: Source -> THStatus -> ByteString -> IO [ByteString]
push src (THStatus len lines prepend) bs
        -- Too many bytes
        | len > maxTotalHeaderLength = throwIO OverLargeHeader
        | otherwise = push' mnl
  where
    bsLen = S.length bs
    mnl = do
        nl <- S.elemIndex 10 bs
        -- check if there are two more bytes in the bs
        -- if so, see if the second of those is a horizontal space
        if bsLen > nl + 1 then
            let c = S.index bs (nl + 1)
                b = case nl of
                      0 -> True
                      1 -> S.index bs 0 == 13
                      _ -> False
            in Just (nl, (not b) && (c == 32 || c == 9))
            else
            Just (nl, False)

    {-# INLINE push' #-}
    -- No newline find in this chunk.  Add it to the prepend,
    -- update the length, and continue processing.
    push' Nothing = do
        bs' <- readSource src
        if S.null bs'
            then close
            else push src status bs' -- FIXME worker-wrapper transform
      where
        len' = len + bsLen
        prepend' = prepend . S.append bs
        status = THStatus len' lines prepend'
    -- Found a newline, but next line continues as a multiline header
    push' (Just (end, True)) = push src status rest
      where
        rest = S.drop (end + 1) bs
        prepend' = prepend . S.append (SU.unsafeTake (checkCR bs end) bs)
        len' = len + end
        status = THStatus len' lines prepend'
    -- Found a newline at position end.
    push' (Just (end, False))
      -- leftover
      | S.null line = do
            let lines' = lines []
            when (start < bsLen) $ leftoverSource (SU.unsafeDrop start bs) src
            return lines'
      -- more headers
      | otherwise   = let len' = len + start
                          lines' = lines . (line:)
                          status = THStatus len' lines' id
                      in if start < bsLen then
                             -- more bytes in this chunk, push again
                             let bs' = SU.unsafeDrop start bs
                              in push src status bs'
                           else do
                             -- no more bytes in this chunk, ask for more
                             bs' <- readSource src
                             if S.null bs'
                                 then close
                                 else push src status bs'
      where
        start = end + 1 -- start of next chunk
        line
          -- There were some bytes before the newline, get them
          | end > 0 = prepend $ SU.unsafeTake (checkCR bs end) bs
          -- No bytes before the newline
          | otherwise = prepend S.empty

{-# INLINE checkCR #-}
checkCR :: ByteString -> Int -> Int
checkCR bs pos = if 13 == S.index bs p then p else pos -- 13 is CR
  where
    !p = pos - 1
