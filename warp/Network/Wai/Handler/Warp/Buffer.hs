module Network.Wai.Handler.Warp.Buffer where

import qualified Blaze.ByteString.Builder.Internal.Buffer as B (Buffer (..))
import Data.Word (Word8, Word)
import Foreign.ForeignPtr (newForeignPtr_)
import Foreign.Marshal.Alloc (mallocBytes, free)
import Foreign.Ptr (Ptr, plusPtr)
import Data.ByteString.Internal (mallocByteString)
import Network.Wai.Handler.Warp.IORef
import GHC.Ptr (Ptr (..))
import GHC.ForeignPtr (ForeignPtr (..))
import Control.Monad (when, join)

data LargeBuffer = LargeBuffer
    { lbufferPtr :: {-# UNPACK #-} !(ForeignPtr Word8)
    , lbufferSize :: {-# UNPACK #-} !Int
    }
type BufferPool = IORef [LargeBuffer]

newLargeBuffer :: Int -> IO LargeBuffer
newLargeBuffer size = do
    fptr <- mallocByteString size
    return $! LargeBuffer fptr size
{-# INLINE newLargeBuffer #-}

-- Taken from vector
updPtr :: (Ptr a -> Ptr a) -> ForeignPtr a -> ForeignPtr a
{-# INLINE updPtr #-}
updPtr f (ForeignPtr p c) = case f (Ptr p) of { Ptr q -> ForeignPtr q c }

withBuffer :: BufferPool -> (ForeignPtr Word8 -> Int -> IO (a, Int)) -> IO a
withBuffer pool f = do
    -- Not worrying about exception safety: if any exceptions are thrown, we'll
    -- just drop the pool on the floor.
    LargeBuffer fptr size <- getBuffer pool
    (res, used) <- f fptr size
    let size' = size - used
        fptr' = updPtr (`plusPtr` used) fptr
    when (size' > minSize) $ putBuffer pool $! LargeBuffer fptr' size'
    return $! res
  where
    minSize = 2048
{-# INLINE withBuffer #-}

newBufferPool :: IO BufferPool
newBufferPool = newIORef []
{-# INLINE newBufferPool #-}

getBuffer :: BufferPool -> IO LargeBuffer
getBuffer pool = join $ atomicModifyIORef' pool $ \bs ->
    case bs of
        [] -> ([], newLargeBuffer $ 4096 * 256) -- FIXME good size?
        b:bs' -> (bs', return b)
{-# INLINE getBuffer #-}

putBuffer :: BufferPool -> LargeBuffer -> IO ()
putBuffer pool b = atomicModifyIORef' pool $ \bs -> (b:bs, ())

type Buffer = Ptr Word8
type BufSize = Int

-- FIXME come up with good values here
bufferSize :: BufSize
bufferSize = 4096

allocateBuffer :: Int -> IO Buffer
allocateBuffer = mallocBytes

freeBuffer :: Buffer -> IO ()
freeBuffer = free

toBlazeBuffer :: Buffer -> BufSize -> IO B.Buffer
toBlazeBuffer ptr size = do
    fptr <- newForeignPtr_ ptr
    return $ B.Buffer fptr ptr ptr (ptr `plusPtr` size)
