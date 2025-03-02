{-# LANGUAGE CPP #-}
module Crypto.Cipher.Salsa20.LE where

import           Control.Exception        (assert)
import           Control.Monad            (liftM, liftM2, liftM4, void)
import           Data.Binary              (Binary (..), Word32, Word64, Word8)
import           Data.Binary.Get          (getWord32host)
import           Data.Binary.Put          (putWord32host)
import           Data.Bits                (complement, rotateL, unsafeShiftR,
                                           xor, (.&.))
import           Data.ByteString.Internal (ByteString, fromForeignPtr,
                                           toForeignPtr)
import qualified Data.ByteString.Lazy as BL
import           Data.ByteString.Lazy     (fromChunks, toChunks)
import           Foreign                  (ForeignPtr, Ptr, Storable (..),
                                           alignPtr, castForeignPtr, castPtr,
                                           copyBytes, plusPtr, withForeignPtr)
import           System.IO.Unsafe         (unsafeDupablePerformIO)

#if __GLASGOW_HASKELL__ >= 605 && !defined(SLOW_FOREIGN_PTR)
import           GHC.ForeignPtr           (mallocPlainForeignPtrBytes)
#else
import           Foreign.ForeignPtr       (mallocForeignPtrBytes)
#endif

data Quarter = Quarter {-# UNPACK #-} !Word32
                       {-# UNPACK #-} !Word32
                       {-# UNPACK #-} !Word32
                       {-# UNPACK #-} !Word32
                       deriving ( Show, Eq )

instance Storable Quarter where
    {-# INLINE sizeOf #-}
    sizeOf _ = sizeOf (undefined :: Word32) * 4

    {-# INLINE alignment #-}
    alignment _ = alignment (undefined :: Word32)

    {-# INLINE peek #-}
    peek ptr =
        liftM4 Quarter (peekElemOff ptr' 0)
                       (peekElemOff ptr' 1)
                       (peekElemOff ptr' 2)
                       (peekElemOff ptr' 3)
        where
            ptr' = castPtr ptr

    {-# INLINE poke #-}
    poke ptr (Quarter x0 x1 x2 x3) = do
        pokeElemOff ptr' 0 x0
        pokeElemOff ptr' 1 x1
        pokeElemOff ptr' 2 x2
        pokeElemOff ptr' 3 x3
        where
            ptr' = castPtr ptr

instance Binary Quarter where
    {-# INLINE get #-}
    get = liftM4 Quarter getWord32host getWord32host getWord32host getWord32host

    {-# INLINE put #-}
    put (Quarter x0 x1 x2 x3) = do
        putWord32host x0
        putWord32host x1
        putWord32host x2
        putWord32host x3

{-# INLINE plusQuarter #-}
plusQuarter :: Quarter -> Quarter -> Quarter
plusQuarter (Quarter x0 x1 x2 x3) (Quarter y0 y1 y2 y3) = Quarter (x0 + y0) (x1 + y1) (x2 + y2) (x3 + y3)

{-# INLINE xorQuarter #-}
xorQuarter :: Quarter -> Quarter -> Quarter
xorQuarter (Quarter x0 x1 x2 x3) (Quarter y0 y1 y2 y3) = Quarter (x0 `xor` y0) (x1 `xor` y1) (x2 `xor` y2) (x3 `xor` y3)

{-# INLINE quarterRound #-}
quarterRound :: Quarter -> Quarter
quarterRound (Quarter x0 x1 x2 x3) = Quarter y0 y1 y2 y3
    where
        y1 = x1 `xor` ((x0 + x3) `rotateL`  7)
        y2 = x2 `xor` ((y1 + x0) `rotateL`  9)
        y3 = x3 `xor` ((y2 + y1) `rotateL` 13)
        y0 = x0 `xor` ((y3 + y2) `rotateL` 18)

{-# INLINE rotateLeft #-}
rotateLeft :: Quarter -> Quarter
rotateLeft (Quarter x0 x1 x2 x3) = (Quarter x1 x2 x3 x0)

{-# INLINE rotateRight #-}
rotateRight :: Quarter -> Quarter
rotateRight (Quarter x0 x1 x2 x3) = (Quarter x3 x0 x1 x2)

{-# INLINE rotated #-}
rotated :: (Quarter -> Quarter) -> Quarter -> Quarter
rotated f = rotateRight . f . rotateLeft

data Block = Block {-# UNPACK #-} !Quarter
                   {-# UNPACK #-} !Quarter
                   {-# UNPACK #-} !Quarter
                   {-# UNPACK #-} !Quarter
                   deriving ( Show, Eq )

instance Storable Block where
    {-# INLINE sizeOf #-}
    sizeOf _ = sizeOf (undefined :: Quarter) * 4

    {-# INLINE alignment #-}
    alignment _ = alignment (undefined :: Quarter)

    {-# INLINE peek #-}
    peek ptr =
        liftM4 Block (peekElemOff ptr' 0)
                     (peekElemOff ptr' 1)
                     (peekElemOff ptr' 2)
                     (peekElemOff ptr' 3)
        where
            ptr' = castPtr ptr

    {-# INLINE poke #-}
    poke ptr (Block x0 x1 x2 x3) = do
        pokeElemOff ptr' 0 x0
        pokeElemOff ptr' 1 x1
        pokeElemOff ptr' 2 x2
        pokeElemOff ptr' 3 x3
        where
            ptr' = castPtr ptr

instance Binary Block where
    {-# INLINE get #-}
    get = liftM4 Block get get get get

    {-# INLINE put #-}
    put (Block x0 x1 x2 x3) = do
        put x0
        put x1
        put x2
        put x3

{-# INLINE plusBlock #-}
plusBlock :: Block -> Block -> Block
plusBlock (Block x0 x1 x2 x3) (Block y0 y1 y2 y3) = Block (x0 `plusQuarter` y0) (x1 `plusQuarter` y1) (x2 `plusQuarter` y2) (x3 `plusQuarter` y3)

{-# INLINE xorBlock #-}
xorBlock :: Block -> Block -> Block
xorBlock (Block x0 x1 x2 x3) (Block y0 y1 y2 y3) = Block (x0 `xorQuarter` y0) (x1 `xorQuarter` y1) (x2 `xorQuarter` y2) (x3 `xorQuarter` y3)

{-# INLINE rowRound #-}
rowRound :: Block -> Block
rowRound (Block x0 x1 x2 x3) = Block y0 y1 y2 y3
    where
        y0 =                               quarterRound x0
        y1 =  rotated                      quarterRound x1
        y2 = (rotated . rotated)           quarterRound x2
        y3 = (rotated . rotated . rotated) quarterRound x3

{-# INLINE transpose #-}
transpose :: Block -> Block
transpose (Block (Quarter  x0  x1  x2  x3)
                 (Quarter  x4  x5  x6  x7)
                 (Quarter  x8  x9 x10 x11)
                 (Quarter x12 x13 x14 x15)) =
           Block (Quarter  x0  x4  x8 x12)
                 (Quarter  x1  x5  x9 x13)
                 (Quarter  x2  x6 x10 x14)
                 (Quarter  x3  x7 x11 x15)

{-# INLINE transposed #-}
transposed :: (Block -> Block) -> Block -> Block
transposed f = transpose . f . transpose

{-# INLINE columnRound #-}
columnRound :: Block -> Block
columnRound = transposed rowRound

{-# INLINE doubleRound #-}
doubleRound :: Block -> Block
doubleRound = rowRound . columnRound

type Core = Block -> Block

{-# INLINE salsa #-}
salsa :: Int -> Core
salsa rounds initBlock = assert ((even rounds) && (rounds > 0)) $ go (rounds `unsafeShiftR` 1) initBlock
    where
        go 0 block = block `plusBlock` initBlock
        go n block = go (n - 1) $! doubleRound block

class Key a where
    expand :: Core -> a -> Quarter -> Block

{-# INLINE expandSigma #-}
expandSigma :: Core -> Quarter -> Quarter -> Quarter -> Quarter -> Block
expandSigma salsaCore
            (Quarter  s0  s1  s2  s3)
            (Quarter k00 k01 k02 k03)
            (Quarter k10 k11 k12 k13)
            (Quarter  n0  n1  n2  n3) =
            salsaCore $ Block
            (Quarter  s0 k00 k01 k02)
            (Quarter k03  s1  n0  n1)
            (Quarter  n2  n3  s2 k10)
            (Quarter k11 k12 k13  s3)

newtype Key128 = Key128 Quarter deriving ( Show, Eq )

instance Key Key128 where
    {-# INLINE expand #-}
    expand core (Key128 k0) = expandSigma core (Quarter 0x61707865 0x3120646e 0x79622d36 0x6b206574) k0 k0

instance Binary Key128 where
    {-# INLINE get #-}
    get = liftM Key128 get

    {-# INLINE put #-}
    put (Key128 quarter) = put quarter

data Key256 = Key256 {-# UNPACK #-} !Quarter
                     {-# UNPACK #-} !Quarter
              deriving ( Show, Eq )

instance Key Key256 where
    {-# INLINE expand #-}
    expand core (Key256 k0 k1) = expandSigma core (Quarter 0x61707865 0x3320646e 0x79622d32 0x6b206574) k0 k1

instance Binary Key256 where
    {-# INLINE get #-}
    get = liftM2 Key256 get get

    {-# INLINE put #-}
    put (Key256 x0 x1) = do
        put x0
        put x1

data Nounce = Nounce {-# UNPACK #-} !Word32
                     {-# UNPACK #-} !Word32
              deriving ( Show, Eq )

instance Binary Nounce where
    {-# INLINE get #-}
    get = liftM2 Nounce getWord32host getWord32host

    {-# INLINE put #-}
    put (Nounce x0 x1) = do
        putWord32host x0
        putWord32host x1

data KeyStream = KeyStream {-# UNPACK #-} !Block
                                           KeyStream
                 deriving ( Show, Eq )

{-# SPECIALISE INLINE keyStream :: Core -> Key128 -> Nounce -> Word64 -> KeyStream #-}
{-# SPECIALISE INLINE keyStream :: Core -> Key256 -> Nounce -> Word64 -> KeyStream #-}
keyStream :: (Key key) => Core -> key -> Nounce -> Word64 -> KeyStream
keyStream core key (Nounce n0 n1) = go
    where
        go i = KeyStream (expand' i) $ go (i + 1)
        expand' i = expand core key $ Quarter n0 n1 (fromIntegral i) (fromIntegral $ i `unsafeShiftR` 32)

newtype CryptProcess = CryptProcess { runCryptProcess :: ByteString -> (ByteString, CryptProcess) }

crypt :: (Key key) => Core -> key -> Nounce -> Word64 -> CryptProcess
crypt core key nounce seqNum = CryptProcess $ startCrypt $ keyStream core key nounce seqNum

cryptString :: (Key key) => Core -> key -> Nounce -> BL.ByteString -> BL.ByteString
cryptString core key nounce = fromChunks . go (crypt core key nounce 0) . toChunks
    where
        go _ [] = []
        go (CryptProcess cp) (x : xs) = let (crypted, cp') = cp x in crypted : go cp' xs

{-# INLINE startCrypt #-}
startCrypt :: KeyStream -> ByteString -> (ByteString, CryptProcess)
startCrypt key src
    -- skip empty block
    | srcLen == 0 = (src, CryptProcess $ startCrypt key)

    -- crypt less then one block and store key remains
    | srcLen < blockSize =
        cryptChunk blockSize $ \dstPtr srcPtr -> do
            nextKey <- remainsXor dstPtr srcPtr key srcLen
            continueCryptProcess srcLen (blockSize - srcLen) nextKey

    -- crypt whole number of blocks (more than one, one is handled by special case)
    | remains == 0 =
        cryptChunk srcLen $ \dstPtr srcPtr -> do
            nextKey <- fst <$> blockXor dstPtr srcPtr key srcLen
            newCryptProcess nextKey

    -- crypt whole number of blocks + part of the key and store key remains for the next step
    | otherwise =
        cryptChunk (srcLen + blockSize - remains) $ \dstPtr srcPtr -> do
            (nextKey, encoded) <- blockXor dstPtr srcPtr key srcLen
            nextKey' <- remainsXor (dstPtr `plusPtr` encoded) (srcPtr `plusPtr` encoded) nextKey remains
            continueCryptProcess srcLen (blockSize - remains) nextKey'
    where
        (srcFp, srcOffset, srcLen) = toForeignPtr src
        remains = assert (blockSize == 64) $ srcLen .&. 0x3F

        {-# INLINE cryptChunk #-}
        cryptChunk :: Int -> (Ptr Block -> Ptr Word8 ->  IO (ForeignPtr Block -> CryptProcess)) -> (ByteString, CryptProcess)
        cryptChunk size f = createChunk size 0 srcLen $ \dstFp -> do
            cont <- withForeignPtr dstFp $ \dstBasePtr ->
                    withForeignPtr srcFp $ \srcBasePtr ->
                    f dstBasePtr (srcBasePtr `plusPtr` srcOffset)
            return $ cont dstFp

{-# INLINE continueCrypt #-}
continueCrypt :: ByteString -> KeyStream -> ByteString -> (ByteString, CryptProcess)
continueCrypt storedKey key  src
    -- skip empty block
    | srcLen == 0 = (src, CryptProcess $ continueCrypt storedKey key)

    -- use some of key remains to encode the block and store remains in the new block to allow GC reclaim old block
    | srcLen < keyLen =
        cryptChunk keyLen 0 $ \dstPtr srcPtr keyPtr -> do
            (dstPtr', _, keyPtr') <- bytesXor3 (castPtr dstPtr) srcPtr keyPtr srcLen
            copyBytes dstPtr' keyPtr' (keyLen - srcLen)
            continueCryptProcess srcLen (keyLen - srcLen) key

    -- use all key remains to encode chunk
    | srcLen == keyLen =
        cryptChunk srcLen 0 $ \dstPtr srcPtr keyPtr -> do
            void $ bytesXor3 (castPtr dstPtr) srcPtr keyPtr srcLen
            newCryptProcess key

    -- use all key remains to encode the block and part of a new key to encode the rest
    | srcLen < blockSize = assert (srcLen > keyLen) $
        cryptChunk (blockSize + blockSize) keyUsed $ \dstPtr srcPtr keyPtr -> do
            (dstPtr', srcPtr', _) <- bytesXor3 (castPtr dstPtr) srcPtr keyPtr keyLen
            nextKey <- remainsXor (castPtr dstPtr') srcPtr' key remains
            continueCryptProcess (srcLen + keyUsed) (blockSize - remains) nextKey

    -- use all key remains + some whole key blocks
    | remains == 0 = assert (srcLen >= blockSize) $
        cryptChunk (srcLen + blockSize) keyUsed $ \dstPtr srcPtr keyPtr -> do
            (dstPtr', srcPtr', _) <- bytesXor3 (castPtr dstPtr) srcPtr keyPtr keyLen
            nextKey <- fst <$> blockXor (castPtr dstPtr') srcPtr' key (srcLen - keyLen)
            newCryptProcess nextKey

    -- use all key remains + some whole key blocks + part of the key and store key remains for the next step
    |  otherwise = assert (remains > 0 && srcLen >= blockSize) $
        cryptChunk (srcLen + blockSize + blockSize) keyUsed $ \dstPtr srcPtr keyPtr -> do
            (dstPtr', srcPtr', _) <- bytesXor3 (castPtr dstPtr) srcPtr keyPtr keyLen
            (nextKey, encoded) <- blockXor (castPtr dstPtr') srcPtr' key (srcLen - keyLen - remains)
            nextKey' <- remainsXor (dstPtr' `plusPtr` encoded) (srcPtr' `plusPtr` encoded) nextKey remains
            continueCryptProcess (srcLen + keyUsed) (blockSize - remains) nextKey'
    where
        (keyFp, keyOffset, keyLen) = toForeignPtr storedKey
        (srcFp, srcOffset, srcLen) = toForeignPtr src
        keyUsed = blockSize - keyLen
        remains = assert (blockSize == 64) $ (srcLen - keyLen) .&. 0x3F

        {-# INLINE cryptChunk #-}
        cryptChunk :: Int -> Int -> (Ptr Block -> Ptr Word8 -> Ptr Word8 -> IO (ForeignPtr Block -> CryptProcess)) -> (ByteString, CryptProcess)
        cryptChunk size offset f = createChunk size offset srcLen $ \dstFp -> do
            cont <- withForeignPtr dstFp $ \dstBasePtr ->
                    withForeignPtr srcFp $ \srcBasePtr ->
                    withForeignPtr keyFp $ \keyBasePtr ->
                    f (dstBasePtr `plusPtr` offset) (srcBasePtr `plusPtr` srcOffset) (keyBasePtr `plusPtr` keyOffset)
            return $ cont dstFp

{-# INLINE blockSize #-}
blockSize :: Int
blockSize = sizeOf (undefined :: Block)

{-# INLINE createChunk #-}
createChunk :: Int -> Int -> Int -> (ForeignPtr Block -> IO CryptProcess) -> (ByteString, CryptProcess)
createChunk size offset len f = unsafeDupablePerformIO $ do
#if __GLASGOW_HASKELL__ >= 605 && !defined(SLOW_FOREIGN_PTR)
    dstFp <- mallocPlainForeignPtrBytes size
#else
    dstFp <- mallocForeignPtrBytes size
#endif
    process <- f dstFp
    return (fromForeignPtr (castForeignPtr dstFp) offset len, process)

{-# INLINE newCryptProcess #-}
newCryptProcess :: KeyStream -> IO (ForeignPtr Block -> CryptProcess)
newCryptProcess key = return $ const $ CryptProcess $ startCrypt key

{-# INLINE continueCryptProcess #-}
continueCryptProcess :: Int -> Int -> KeyStream -> IO (ForeignPtr Block -> CryptProcess)
continueCryptProcess keyOffset keyLength key =
    return $ \dstFp -> CryptProcess $ continueCrypt (fromForeignPtr (castForeignPtr dstFp) keyOffset keyLength) key

-- | Encrypt whole number of blocks.
-- Number of bytes encrypted will be truncated to block boundary.
-- Returns unconsumed keystream and number of bytes actually xored
{-# INLINE blockXor #-}
blockXor :: Ptr Block -> Ptr Word8 -> KeyStream -> Int -> IO (KeyStream, Int)
blockXor dstPtr srcPtr key size
    | srcPtr `alignPtr` alignment (undefined :: Block) == srcPtr = do
        stream <- blockXor3 dstPtr (castPtr srcPtr) key blockBytes
        return (stream, blockBytes)
    | otherwise = do
        copyBytes (castPtr dstPtr) srcPtr blockBytes
        stream <- blockXor2 dstPtr key blockBytes
        return (stream, blockBytes)
    where
        blockBytes = assert (blockSize == 64) $ size .&. (complement 0x3F)

-- | 2-address block crypt
{-# INLINE blockXor2 #-}
blockXor2 :: Ptr Block -> KeyStream -> Int -> IO KeyStream
blockXor2 dstPtr k@(KeyStream key nextKey) size
    | size == 0 = return k
    | otherwise = assert (size `rem` blockSize == 0) $ do
        block <- peek dstPtr
        poke dstPtr $ block `xorBlock` key
        blockXor2 (dstPtr `plusPtr` blockSize) nextKey (size - blockSize)

-- | 3-address block crypt
{-# INLINE blockXor3 #-}
blockXor3 :: Ptr Block -> Ptr Block -> KeyStream -> Int -> IO KeyStream
blockXor3 dstPtr srcPtr k@(KeyStream key nextKey) size
    | size == 0 = return k
    | otherwise = assert (size `rem` blockSize == 0) $ do
        block <- peek srcPtr
        poke dstPtr $ block `xorBlock` key
        blockXor3 (dstPtr `plusPtr` blockSize) (srcPtr `plusPtr` blockSize) nextKey (size - blockSize)

-- | Encrypt remaining bytes and store unused part of the key right after the encrypted data
{-# INLINE remainsXor #-}
remainsXor :: Ptr Block -> Ptr Word8 -> KeyStream -> Int -> IO KeyStream
remainsXor dstPtr srcPtr (KeyStream key nextKey) size = assert (size > 0 && size < blockSize) $ do
    poke dstPtr key
    void $ bytesXor2 (castPtr dstPtr) srcPtr size
    return nextKey

-- | 2-address string xor
{-# INLINE bytesXor2 #-}
bytesXor2 :: Ptr Word8 -> Ptr Word8 -> Int -> IO (Ptr Word8, Ptr Word8)
bytesXor2 dstPtr srcPtr count
    | count == 0 = return (dstPtr, srcPtr)
    | otherwise = assert (count > 0) $ do
        x <- peek dstPtr
        y <- peek srcPtr
        poke dstPtr (x `xor` y)
        bytesXor2 (dstPtr `plusPtr` 1) (srcPtr `plusPtr` 1) (count - 1)

-- | 3-address string xor
{-# INLINE bytesXor3 #-}
bytesXor3 :: Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> Int -> IO (Ptr Word8, Ptr Word8, Ptr Word8)
bytesXor3 dstPtr srcPtr keyPtr count
    | count == 0 = return (dstPtr, srcPtr, keyPtr)
    | otherwise = assert (count > 0) $ do
        x <- peek srcPtr
        y <- peek keyPtr
        poke dstPtr (x `xor` y)
        bytesXor3 (dstPtr `plusPtr` 1) (srcPtr `plusPtr` 1) (keyPtr `plusPtr` 1) (count - 1) 