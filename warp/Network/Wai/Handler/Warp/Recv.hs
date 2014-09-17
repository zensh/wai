{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE CPP #-}

module Network.Wai.Handler.Warp.Recv (
    receive
  ) where

import Control.Applicative ((<$>))
import qualified Data.ByteString as BS (empty)
import Data.ByteString.Internal (ByteString(..))
import Data.Word (Word8)
import Foreign.C.Error (eAGAIN, getErrno, throwErrno)
import Foreign.C.Types
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Ptr (Ptr)
import GHC.Conc (threadWaitRead)
import Network.Socket (Socket, fdSocket)
import System.Posix.Types (Fd(..))
import Network.Wai.Handler.Warp.Buffer

#ifdef mingw32_HOST_OS
import GHC.IO.FD (FD(..), readRawBufferPtr)
import Network.Wai.Handler.Warp.Windows
#endif

----------------------------------------------------------------

receive :: Socket -> BufferPool -> IO ByteString
receive sock bufPool = withBuffer bufPool $ \fptr size -> do
    let size' = fromIntegral size
    bytes <- withForeignPtr fptr $ \buf ->
             fromIntegral <$> receiveloop sock' buf size'
    let bs = if bytes == 0
                then BS.empty
                else PS fptr 0 bytes
    return (bs, bytes)
  where
    sock' = fdSocket sock

receiveloop :: CInt -> Ptr Word8 -> CSize -> IO CInt
receiveloop sock buf size = do
#ifdef mingw32_HOST_OS
    bytes <- windowsThreadBlockHack $ fmap fromIntegral $ readRawBufferPtr "recv" (FD sock 1) buf 0 size
#else
    bytes <- c_recv sock buf size 0
#endif
    if bytes == -1 then do
        errno <- getErrno
        if errno == eAGAIN then do
            threadWaitRead (Fd sock)
            receiveloop sock buf size
          else
            throwErrno "receiveloop"
       else
        return bytes

-- fixme: the type of the return value
foreign import ccall unsafe "recv"
    c_recv :: CInt -> Ptr Word8 -> CSize -> CInt -> IO CInt
