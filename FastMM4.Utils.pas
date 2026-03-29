unit FastMM4.Utils;

interface

type

  TSmallBlockTypeState = record
    {The internal size of the block type}
    InternalBlockSize: Cardinal;
    {Useable block size: The number of non-reserved bytes inside the block.}
    UseableBlockSize: Cardinal;
    {The number of allocated blocks}
    AllocatedBlockCount: NativeUInt;
    {The total address space reserved for this block type (both allocated and
     free blocks)}
    ReservedAddressSpace: NativeUInt;
  end;
  TSmallBlockTypeStates = array[0..NumSmallBlockTypes - 1] of TSmallBlockTypeState;

  TMemoryManagerState = record
    {Small block type states}
    SmallBlockTypeStates: TSmallBlockTypeStates;
    {Medium block stats}
    AllocatedMediumBlockCount: Cardinal;
    TotalAllocatedMediumBlockSize: NativeUInt;
    ReservedMediumBlockAddressSpace: NativeUInt;
    {Large block stats}
    AllocatedLargeBlockCount: Cardinal;
    TotalAllocatedLargeBlockSize: NativeUInt;
    ReservedLargeBlockAddressSpace: NativeUInt;
  end;

  TMemoryManagerUsageSummary = record
    {The total number of bytes allocated by the application.}
    AllocatedBytes: NativeUInt;
    {The total number of address space bytes used by control structures, or
     lost due to fragmentation and other overhead.}
    OverheadBytes: NativeUInt;
    {The efficiency of the memory manager expressed as a percentage. This is
     100 * AllocatedBytes / (AllocatedBytes + OverheadBytes).}
    EfficiencyPercentage: Double;
  end;

  {Memory map}
  TChunkStatus = (csUnallocated, csAllocatedSmall, csAllocatedMedium, csAllocatedLarge, csReservedMedium, csSysAllocated, csSysReserved);
  TMemoryMap = array[0..65535] of TChunkStatus;

  {The callback procedure for WalkAllocatedBlocks.}
  TWalkAllocatedBlocksCallback = procedure(APBlock: Pointer; ABlockSize: NativeInt; AUserData: Pointer);

{Returns summarised information about the state of the memory manager. (For
 backward compatibility.)}
function FastGetHeapStatus: THeapStatus;
{Returns statistics about the current state of the memory manager}
procedure GetMemoryManagerState(var AMemoryManagerState: TMemoryManagerState);
{Returns a summary of the information returned by GetMemoryManagerState}
function GetMemoryManagerUsageSummary: TMemoryManagerUsageSummary; overload;
procedure GetMemoryManagerUsageSummary(var AMemoryManagerUsageSummary: TMemoryManagerUsageSummary); overload;
{$IFNDEF POSIX}
{Gets the state of every 64K block in the 4GB address space}
procedure GetMemoryMap(var AMemoryMap: TMemoryMap);
{$ENDIF}
{Walks all allocated blocks, calling ACallBack for each. Passes the user block size and AUserData to the callback.
 Important note: All block types will be locked during the callback, so the memory manager cannot be used inside it.}
procedure WalkAllocatedBlocks(ACallBack: TWalkAllocatedBlocksCallback; AUserData: Pointer);
{Writes a log file containing a summary of the memory manager state and a summary of allocated blocks grouped by
 class. The file will be saved in UTF-8 encoding (in supported Delphi versions). Returns True on success. }
function LogMemoryManagerStateToFile(const AFileName: string; const AAdditionalDetails: string {$IFNDEF FPC}= ''{$ENDIF}): Boolean;

implementation

uses

  FastMM4;

{Returns statistics about the current state of the memory manager}
procedure GetMemoryManagerState(var AMemoryManagerState: TMemoryManagerState);
const
  BlockHeaderSizeWithAnyOverhead = BlockHeaderSize{$IFDEF FullDebugMode} + FullDebugBlockOverhead{$ENDIF};
var
  LIndBlockSize,
  LUsableBlockSize: Cardinal;
  LPMediumBlockPoolHeader: PMediumBlockPoolHeader;
  LPMediumBlock: Pointer;
  LInd: Integer;
  LBlockTypeIndex,
  LMediumBlockSize: Cardinal;
  LMediumBlockHeader,
  LLargeBlockSize: NativeUInt;
  LPLargeBlock: PLargeBlockHeader;
{$IFDEF LogLockContention}
  LDidSleep: Boolean;
{$ENDIF}
{$IFNDEF AssumeMultiThreaded}
  LMediumBlocksLocked: Boolean;
  LLargeBlocksLocked: Boolean;
{$ENDIF}
begin
{$IFNDEF AssumeMultiThreaded}
  LMediumBlocksLocked := False;
  LLargeBlocksLocked := False;
{$ENDIF}
  {Clear the structure}
  FillChar(AMemoryManagerState, SizeOf(AMemoryManagerState), 0);
  {Set the small block size stats}
  for LInd := 0 to NumSmallBlockTypes - 1 do
  begin
    LIndBlockSize := SmallBlockTypes[LInd].BlockSize;
    AMemoryManagerState.SmallBlockTypeStates[LInd].InternalBlockSize := LIndBlockSize;
    if LIndBlockSize > BlockHeaderSizeWithAnyOverhead then
    begin
      LUsableBlockSize := LIndBlockSize - BlockHeaderSizeWithAnyOverhead
    end else
    begin
      LUsableBlockSize := 0;
    end;
    AMemoryManagerState.SmallBlockTypeStates[LInd].UseableBlockSize := LUsableBlockSize;
  end;
{$IFNDEF AssumeMultiThreaded}
  if IsMultiThread then
{$ENDIF}
  begin
    {Lock all small block types}
    LockAllSmallBlockTypes;
    {Lock the medium blocks}
{$IFNDEF AssumeMultiThreaded}
    LMediumBlocksLocked := True;
{$ENDIF}
    {$IFDEF LogLockContention}LDidSleep := {$ENDIF}LockMediumBlocks;
  end;
  {Step through all the medium block pools}
  LPMediumBlockPoolHeader := MediumBlockPoolsCircularList.NextMediumBlockPoolHeader;
  while LPMediumBlockPoolHeader <> @MediumBlockPoolsCircularList do
  begin
    {Add to the medium block used space}
    Inc(AMemoryManagerState.ReservedMediumBlockAddressSpace, MediumBlockPoolSize);
    LPMediumBlock := GetFirstMediumBlockInPool(LPMediumBlockPoolHeader);
    while LPMediumBlock <> nil do
    begin
      LMediumBlockHeader := PNativeUInt(PByte(LPMediumBlock) - BlockHeaderSize)^;
      {Is the block in use?}
      if (LMediumBlockHeader and IsFreeBlockFlag) = 0 then
      begin
        {Get the block size}
        LMediumBlockSize := LMediumBlockHeader and DropMediumAndLargeFlagsMask;
        if (LMediumBlockHeader and IsSmallBlockPoolInUseFlag) <> 0 then
        begin
          {Get the block type index}
          LBlockTypeIndex := (UIntPtr(PSmallBlockPoolHeader(LPMediumBlock)^.BlockType) - UIntPtr(@SmallBlockTypes[0]))
    {$IFDEF SmallBlockTypeRecSizeIsPowerOf2}
          shr SmallBlockTypeRecSizePowerOf2
    {$ELSE}
          div SmallBlockTypeRecSize
    {$ENDIF}
          ;
          {Subtract from medium block usage}
          Dec(AMemoryManagerState.ReservedMediumBlockAddressSpace, LMediumBlockSize);
          {Add it to the reserved space for the block size}
          Inc(AMemoryManagerState.SmallBlockTypeStates[LBlockTypeIndex].ReservedAddressSpace, LMediumBlockSize);
          {Add the usage for the pool}
          Inc(AMemoryManagerState.SmallBlockTypeStates[LBlockTypeIndex].AllocatedBlockCount,
            PSmallBlockPoolHeader(LPMediumBlock)^.BlocksInUse);
        end
        else
        begin
{$IFDEF FullDebugMode}
          Dec(LMediumBlockSize, FullDebugBlockOverhead);
{$ENDIF}
          Inc(AMemoryManagerState.AllocatedMediumBlockCount);
          Inc(AMemoryManagerState.TotalAllocatedMediumBlockSize, LMediumBlockSize - BlockHeaderSize);
        end;
      end;
      {Next medium block}
      LPMediumBlock := NextMediumBlock(LPMediumBlock);
    end;
    {Get the next medium block pool}
    LPMediumBlockPoolHeader := LPMediumBlockPoolHeader^.NextMediumBlockPoolHeader;
  end;
  {Unlock medium blocks}
{$IFNDEF AssumeMultiThreaded}
  if LMediumBlocksLocked then
{$ENDIF}
  begin
    // LMediumBlocksLocked := False; {this assignment produces a compiler "hint", but might have been useful for further development}
    UnlockMediumBlocks;
  end;
  {Unlock all the small block types}
  for LInd := 0 to NumSmallBlockTypes - 1 do
  begin
    ReleaseLockByte(SmallBlockTypes[LInd].SmallBlockTypeLocked);
  end;
{$IFNDEF AssumeMultiThreaded}
  if IsMultiThread then
{$ENDIF}
  begin
{$IFNDEF AssumeMultiThreaded}
    LLargeBlocksLocked := True;
{$ENDIF}
    {Step through all the large blocks}
    {$IFDEF LogLockContention}LDidSleep:={$ENDIF}
    LockLargeBlocks;
  end;
  LPLargeBlock := LargeBlocksCircularList.NextLargeBlockHeader;
  while LPLargeBlock <> @LargeBlocksCircularList do
  begin
    LLargeBlockSize := LPLargeBlock^.BlockSizeAndFlags and DropMediumAndLargeFlagsMask;
    Inc(AMemoryManagerState.AllocatedLargeBlockCount);
    Inc(AMemoryManagerState.ReservedLargeBlockAddressSpace, LLargeBlockSize);
    Inc(AMemoryManagerState.TotalAllocatedLargeBlockSize, LPLargeBlock^.UserAllocatedSize);
    {Get the next large block}
    LPLargeBlock := LPLargeBlock^.NextLargeBlockHeader;
  end;
{$IFNDEF AssumeMultiThreaded}
  if LLargeBlocksLocked then
{$ENDIF}
  begin
    // LLargeBlocksLocked := False; {this assignment produces a compiler "hint", but might have been useful for further development}
    UnlockLargeBlocks;
  end;
end;

{Returns a summary of the information returned by GetMemoryManagerState}
function GetMemoryManagerUsageSummary: TMemoryManagerUsageSummary;
var
  LMMS: TMemoryManagerState;
  LAllocatedBytes,
  LReservedBytes: NativeUInt;
  LSBTIndex: Integer;
begin
  {Get the memory manager state}
  FillChar(LMMS, SizeOf(LMMS), 0);
  GetMemoryManagerState(LMMS);
  {Add up the totals}
  LAllocatedBytes := LMMS.TotalAllocatedMediumBlockSize + LMMS.TotalAllocatedLargeBlockSize;
  LReservedBytes := LMMS.ReservedMediumBlockAddressSpace + LMMS.ReservedLargeBlockAddressSpace;
  for LSBTIndex := 0 to NumSmallBlockTypes - 1 do
  begin
    Inc(LAllocatedBytes, LMMS.SmallBlockTypeStates[LSBTIndex].UseableBlockSize
      * LMMS.SmallBlockTypeStates[LSBTIndex].AllocatedBlockCount);
    Inc(LReservedBytes, LMMS.SmallBlockTypeStates[LSBTIndex].ReservedAddressSpace);
  end;
  {Set the structure values}
  Result.AllocatedBytes := LAllocatedBytes;
  Result.OverheadBytes := LReservedBytes - LAllocatedBytes;
  if LReservedBytes > 0 then
    Result.EfficiencyPercentage := LAllocatedBytes / LReservedBytes * 100
  else
    Result.EfficiencyPercentage := 100;
end;

procedure GetMemoryManagerUsageSummary(var AMemoryManagerUsageSummary: TMemoryManagerUsageSummary);
begin
  AMemoryManagerUsageSummary := GetMemoryManagerUsageSummary;
end;

{$IFNDEF POSIX}
{Gets the state of every 64K block in the 4GB address space. Under 64-bit this
 returns only the state for the low 4GB.}
procedure GetMemoryMap(var AMemoryMap: TMemoryMap);
var
  LPMediumBlock: Pointer;
  LPMediumBlockPoolHeader: PMediumBlockPoolHeader;
  LMediumBlockSize: Cardinal;
  LPLargeBlock: PLargeBlockHeader;
  LIndNUI,
  LChunkIndex,
  LNextChunk,
  LMediumBlockHeader,
  LLargeBlockSize: NativeUInt;
  ChunkStatus: TChunkStatus;
  LMBI: TMemoryBasicInformation;
  LCharToFill: AnsiChar;
{$IFDEF LogLockContention}
  LDidSleep: Boolean;
{$ENDIF}
{$IFNDEF AssumeMultiThreaded}
  LMediumBlocksLocked: Boolean;
  LLargeBlocksLocked: Boolean;
{$ENDIF}
begin
{$IFNDEF AssumeMultiThreaded}
  LMediumBlocksLocked := False;
  LLargeBlocksLocked := False;
{$ENDIF}
  {Clear the map}
  FillChar(AMemoryMap, SizeOf(AMemoryMap), Ord(csUnallocated));
  {Step through all the medium block pools}
{$IFNDEF AssumeMultiThreaded}
  if IsMultiThread then
{$ENDIF}
  begin
{$IFNDEF AssumeMultiThreaded}
    LMediumBlocksLocked := True;
{$ENDIF}
    {$IFDEF LogLockContention}LDidSleep := {$ENDIF}LockMediumBlocks;
  end;
  LPMediumBlockPoolHeader := MediumBlockPoolsCircularList.NextMediumBlockPoolHeader;
  while LPMediumBlockPoolHeader <> @MediumBlockPoolsCircularList do
  begin
    {Add to the medium block used space}
    LChunkIndex := NativeUInt(LPMediumBlockPoolHeader) shr 16;
    for LIndNUI := 0 to (MediumBlockPoolSize - 1) shr 16 do
    begin
      if (LChunkIndex + LIndNUI) > High(AMemoryMap) then
        Break;
      AMemoryMap[LChunkIndex + LIndNUI] := csReservedMedium;
    end;

    LPMediumBlock := GetFirstMediumBlockInPool(LPMediumBlockPoolHeader);
    while LPMediumBlock <> nil do
    begin
      LMediumBlockHeader := PNativeUInt(PByte(LPMediumBlock) - BlockHeaderSize)^;
      if (LMediumBlockHeader and IsFreeBlockFlag) = 0 then
      begin
        if (LMediumBlockHeader and IsSmallBlockPoolInUseFlag) <> 0
          then ChunkStatus:=csAllocatedSmall
          else ChunkStatus:=csAllocatedMedium;
        {Get the block size}
        LMediumBlockSize := LMediumBlockHeader and DropMediumAndLargeFlagsMask;
        LChunkIndex := NativeUInt(LPMediumBlock) shr 16;
        for LIndNUI := 0 to (LMediumBlockSize - 1) shr 16 do
        begin
          if (LChunkIndex + LIndNUI) > High(AMemoryMap) then
            Break;
          AMemoryMap[LChunkIndex + LIndNUI] := ChunkStatus;
        end;
      end;
      {Next medium block}
      LPMediumBlock := NextMediumBlock(LPMediumBlock);
    end;
    {Get the next medium block pool}
    LPMediumBlockPoolHeader := LPMediumBlockPoolHeader^.NextMediumBlockPoolHeader;
  end;

{$IFNDEF AssumeMultiThreaded}
  if LMediumBlocksLocked then
{$ENDIF}
  begin
    // LMediumBlocksLocked := False; {this assignment produces a compiler "hint", but might have been useful for further development}
    UnlockMediumBlocks;
  end;
  {Step through all the large blocks}
{$IFNDEF AssumeMultiThreaded}
  if IsMultiThread then
{$ENDIF}
  begin
{$IFNDEF AssumeMultiThreaded}
    LLargeBlocksLocked := True;
{$ENDIF}
    {$IFDEF LogLockContention}LDidSleep:={$ENDIF}
    LockLargeBlocks;
  end;
  LPLargeBlock := LargeBlocksCircularList.NextLargeBlockHeader;
  while LPLargeBlock <> @LargeBlocksCircularList do
  begin
    LChunkIndex := UIntPtr(LPLargeBlock) shr 16;
    LLargeBlockSize := LPLargeBlock^.BlockSizeAndFlags and DropMediumAndLargeFlagsMask;
    for LIndNUI := 0 to (LLargeBlockSize - 1) shr 16 do
    begin
      if (LChunkIndex + LIndNUI) > High(AMemoryMap) then
        Break;
      AMemoryMap[LChunkIndex + LIndNUI] := csAllocatedLarge;
    end;
    {Get the next large block}
    LPLargeBlock := LPLargeBlock^.NextLargeBlockHeader;
  end;
{$IFNDEF AssumeMultiThreaded}
  if LLargeBlocksLocked then
{$ENDIF}
  begin
    // LLargeBlocksLocked := False; {this assignment produces a compiler "hint", but might have been useful for further development}
    UnlockLargeBlocks;
  end;
  {Fill in the rest of the map}
  LIndNUI := 0;
  while LIndNUI <= 65535 do
  begin
    {If the chunk is not allocated by this MM, what is its status?}
    if AMemoryMap[LIndNUI] = csUnallocated then
    begin
      {Query the address space starting at the chunk boundary}
      if VirtualQuery(Pointer(LIndNUI * 65536), LMBI, SizeOf(LMBI)) = 0 then
      begin
        {VirtualQuery may fail for addresses >2GB if a large address space is
         not enabled.}
        LCharToFill := AnsiChar(csSysReserved);
        FillChar(AMemoryMap[LIndNUI], 65536 - LIndNUI, LCharToFill);
        Break;
      end;
      {Get the chunk number after the region}
      LNextChunk := ((LMBI.RegionSize - 1) shr 16) + LIndNUI + 1;
      {Validate}
      if LNextChunk > 65536 then
        LNextChunk := 65536;
      {Set the status of all the chunks in the region}
      if LMBI.State = MEM_COMMIT then
      begin
        LCharToFill := AnsiChar(csSysAllocated);
        FillChar(AMemoryMap[LIndNUI], LNextChunk - LIndNUI, LCharToFill);
      end
      else
      begin
        if LMBI.State = MEM_RESERVE then
        begin
          LCharToFill := AnsiChar(csSysReserved);
          FillChar(AMemoryMap[LIndNUI], LNextChunk - LIndNUI, LCharToFill);
        end;
      end;
      {Point to the start of the next chunk}
      LIndNUI := LNextChunk;
    end
    else
    begin
      {Next chunk}
      Inc(LIndNUI);
    end;
  end;
end;
{$ENDIF}

{Walks all allocated blocks, calling ACallBack for each. Passes the user block size and AUserData to the callback.
 Important note: All block types will be locked during the callback, so the memory manager cannot be used inside it.}
procedure WalkAllocatedBlocks(ACallBack: TWalkAllocatedBlocksCallback; AUserData: Pointer);
const
  DebugHeaderSize = {$IFDEF FullDebugMode}SizeOf(TFullDebugBlockHeader){$ELSE}0{$ENDIF};
  TotalDebugOverhead = {$IFDEF FullDebugMode}FullDebugBlockOverhead{$ELSE}0{$ENDIF};
var
  LPMediumBlock: Pointer;
  LPMediumBlockPoolHeader: PMediumBlockPoolHeader;
  LMediumBlockHeader: NativeUInt;
  LPLargeBlock: PLargeBlockHeader;
  LBlockSize: NativeInt;
  LPSmallBlockPool: PSmallBlockPoolHeader;
  LCurPtr,
  LEndPtr: Pointer;
  LInd: Integer;
{$IFDEF LogLockContention}
  LDidSleep: Boolean;
{$ENDIF}
{$IFNDEF AssumeMultiThreaded}
  LMediumBlocksLocked: Boolean;
  LLargeBlocksLocked: Boolean;
{$ENDIF}
begin
{$IFNDEF AssumeMultiThreaded}
  LMediumBlocksLocked := False;
  LLargeBlocksLocked := False;
{$ENDIF}
  {Lock all small block types}
  LockAllSmallBlockTypes;
  {Lock the medium blocks}
{$IFNDEF AssumeMultiThreaded}
  if IsMultiThread then
{$ENDIF}
  begin
{$IFNDEF AssumeMultiThreaded}
    LMediumBlocksLocked := True;
{$ENDIF}
    {$IFDEF LogLockContention}LDidSleep := {$ENDIF}LockMediumBlocks;
  end;
  try
    {Step through all the medium block pools}
    LPMediumBlockPoolHeader := MediumBlockPoolsCircularList.NextMediumBlockPoolHeader;
    while LPMediumBlockPoolHeader <> @MediumBlockPoolsCircularList do
    begin
      LPMediumBlock := GetFirstMediumBlockInPool(LPMediumBlockPoolHeader);
      while LPMediumBlock <> nil do
      begin
        LMediumBlockHeader := PNativeUInt(PByte(LPMediumBlock) - BlockHeaderSize)^;
        {Is the block in use?}
        if (LMediumBlockHeader and IsFreeBlockFlag) = 0 then
        begin
          if (LMediumBlockHeader and IsSmallBlockPoolInUseFlag) <> 0 then
          begin
            {Step through all the blocks in the small block pool}
            LPSmallBlockPool := LPMediumBlock;
            {Get the useable size inside a block}
            LBlockSize := LPSmallBlockPool^.BlockType^.BlockSize - BlockHeaderSize - TotalDebugOverhead;
            {Get the first and last pointer for the pool}
            GetFirstAndLastSmallBlockInPool(LPSmallBlockPool, LCurPtr, LEndPtr);
            {Step through all blocks}
            while UIntPtr(LCurPtr) <= UIntPtr(LEndPtr) do
            begin
              {Is this block in use?}
              if (PNativeUInt(PByte(LCurPtr) - BlockHeaderSize)^ and IsFreeBlockFlag) = 0 then
              begin
                ACallBack(PByte(LCurPtr) + DebugHeaderSize, LBlockSize, AUserData);
              end;
              {Next block}
              Inc(PByte(LCurPtr), LPSmallBlockPool^.BlockType^.BlockSize);
            end;
          end
          else
          begin
            LBlockSize := (LMediumBlockHeader and DropMediumAndLargeFlagsMask) - BlockHeaderSize - TotalDebugOverhead;
            ACallBack(PByte(LPMediumBlock) + DebugHeaderSize, LBlockSize, AUserData);
          end;
        end;
        {Next medium block}
        LPMediumBlock := NextMediumBlock(LPMediumBlock);
      end;
      {Get the next medium block pool}
      LPMediumBlockPoolHeader := LPMediumBlockPoolHeader^.NextMediumBlockPoolHeader;
    end;
  finally
    {Unlock medium blocks}
{$IFNDEF AssumeMultiThreaded}
    if LMediumBlocksLocked then
{$ENDIF}
    begin
      // LMediumBlocksLocked := False; {this assignment produces a compiler "hint", but might have been useful for further development}
      UnlockMediumBlocks;
    end;
    {Unlock all the small block types}
    for LInd := 0 to NumSmallBlockTypes - 1 do
    begin
      ReleaseLockByte(SmallBlockTypes[LInd].SmallBlockTypeLocked);
    end;
  end;
{$IFNDEF AssumeMultiThreaded}
  if IsMultiThread then
{$ENDIF}
  begin
{$IFNDEF AssumeMultiThreaded}
    LLargeBlocksLocked := True;
{$ENDIF}
    {Step through all the large blocks}
    {$IFDEF LogLockContention}LDidSleep :={$ENDIF}
    LockLargeBlocks;
  end;
  try
    {Get all leaked large blocks}
    LPLargeBlock := LargeBlocksCircularList.NextLargeBlockHeader;
    while LPLargeBlock <> @LargeBlocksCircularList do
    begin
      LBlockSize := (LPLargeBlock^.BlockSizeAndFlags and DropMediumAndLargeFlagsMask) - BlockHeaderSize - LargeBlockHeaderSize - TotalDebugOverhead;
      ACallBack(PByte(LPLargeBlock) + LargeBlockHeaderSize + DebugHeaderSize, LBlockSize, AUserData);
      {Get the next large block}
      LPLargeBlock := LPLargeBlock^.NextLargeBlockHeader;
    end;
  finally
{$IFNDEF AssumeMultiThreaded}
    if LLargeBlocksLocked then
{$ENDIF}
    begin
      // LLargeBlocksLocked := False; {this assignment produces a compiler "hint", but might have been useful for further development}
      UnlockLargeBlocks;
    end;
  end;
end;

{-----------LogMemoryManagerStateToFile implementation------------}
const
  MaxMemoryLogNodes = 100000;
  QuickSortMinimumItemsInPartition = 4;

type
  {While scanning the memory pool the list of classes is built up in a binary search tree.}
  PMemoryLogNode = ^TMemoryLogNode;
  TMemoryLogNode = record
    {The left and right child nodes}
    LeftAndRightNodePointers: array[Boolean] of PMemoryLogNode;
    {The class this node belongs to}
    ClassPtr: TClass;
    {The number of instances of the class}
    InstanceCount: NativeInt;
    {The total memory usage for this class}
    TotalMemoryUsage: NativeInt;
  end;
  TMemoryLogNodes = array[0..MaxMemoryLogNodes - 1] of TMemoryLogNode;
  PMemoryLogNodes = ^TMemoryLogNodes;

  TMemoryLogInfo = record
    {The number of nodes in "Nodes" that are used.}
    NodeCount: Integer;
    {The root node of the binary search tree. The content of this node is not actually used, it just simplifies the
     binary search code.}
    RootNode: TMemoryLogNode;
    Nodes: TMemoryLogNodes;
  end;
  PMemoryLogInfo = ^TMemoryLogInfo;

{LogMemoryManagerStateToFile callback subroutine}
procedure LogMemoryManagerStateCallBack(APBlock: Pointer; ABlockSize: NativeInt; AUserData: Pointer);
var
  LClass,
  LClassHashBits: NativeUInt;
  LPLogInfo: PMemoryLogInfo;
  LPParentNode,
  LPClassNode: PMemoryLogNode;
  LChildNodeDirection: Boolean;
begin
  LPLogInfo := AUserData;
  {Detecting an object is very expensive (due to the VirtualQuery call), so we do some basic checks and try to find
   the "class" in the tree first.}
  LClass := PNativeUInt(APBlock)^;
  {Do some basic pointer checks: The "class" must be dword aligned and beyond 64K}
  if (LClass > 65535)
    and ((LClass and 3) = 0) then
  begin
    LPParentNode := @LPLogInfo^.RootNode;
    LClassHashBits := LClass;
    repeat
      LChildNodeDirection := Boolean(LClassHashBits and 1);
      {Split off the next bit of the class pointer and traverse in the appropriate direction.}
      LPClassNode := LPParentNode^.LeftAndRightNodePointers[LChildNodeDirection];
      {Is this child node the node the class we're looking for?}
      if (LPClassNode = nil) or (NativeUInt(LPClassNode^.ClassPtr) = LClass) then
        Break;
      {The node was not found: Keep on traversing the tree.}
      LClassHashBits := LClassHashBits shr 1;
      LPParentNode := LPClassNode;
    until False;
  end
  else
    LPClassNode := nil;
  {Was the "class" found?}
  if LPClassNode = nil then
  begin
    {The "class" is not yet in the tree: Determine if it is actually a class.}
    LClass := NativeUInt(DetectClassInstance(APBlock));
    {If it is not a class, try to detect the string type.}
    if LClass = 0 then
      LClass := Ord(DetectStringData(APBlock, ABlockSize));
    {Is this class already in the tree?}
    LPParentNode := @LPLogInfo^.RootNode;
    LClassHashBits := LClass;
    repeat
      LChildNodeDirection := Boolean(LClassHashBits and 1);
      {Split off the next bit of the class pointer and traverse in the appropriate direction.}
      LPClassNode := LPParentNode^.LeftAndRightNodePointers[LChildNodeDirection];
      {Is this child node the node the class we're looking for?}
      if LPClassNode = nil then
      begin
        {The end of the tree was reached: Add a new child node.}
        LPClassNode := @LPLogInfo^.Nodes[LPLogInfo^.NodeCount];
        Inc(LPLogInfo^.NodeCount);
        LPParentNode^.LeftAndRightNodePointers[LChildNodeDirection] := LPClassNode;
        LPClassNode^.ClassPtr := TClass(LClass);
        Break;
      end
      else
      begin
        if NativeUInt(LPClassNode^.ClassPtr) = LClass then
          Break;
      end;
      {The node was not found: Keep on traversing the tree.}
      LClassHashBits := LClassHashBits shr 1;
      LPParentNode := LPClassNode;
    until False;
  end;
  {Update the statistics for the class}
  Inc(LPClassNode^.InstanceCount);
  Inc(LPClassNode^.TotalMemoryUsage, ABlockSize);
end;

{This function is only needed to copy with an error given when using
the "typed @ operator" compiler option. We are having just one typecast
in this function to avoid using typecasts throught the entire program.}
function GetNodeListFromNode(ANode: PMemoryLogNode): PMemoryLogNodes;
  {$IFDEF FASTMM4_ALLOW_INLINES}inline;{$ENDIF}
begin
  {We have only one typecast here, in other places we have strict type checking}
  Result := PMemoryLogNodes(ANode);
end;

{LogMemoryManagerStateToFile subroutine: A median-of-3 quicksort routine for sorting a TMemoryLogNodes array.}
procedure QuickSortLogNodes(APLeftItem: PMemoryLogNodes; ARightIndex: Integer);
var
  LPLeftItem: PMemoryLogNodes;
  LRightIndex: Integer;
  M, I, J: Integer;
  LPivot,
  LTempItem: TMemoryLogNode;
  PMemLogNode: PMemoryLogNode; {This variable is just needed to simplify the accommodation
                                to "typed @ operator" - stores an intermediary value}
begin
  LPLeftItem := APLeftItem;
  LRightIndex := ARightIndex;
  while True do
  begin
    {Order the left, middle and right items in ascending order}
    M := LRightIndex shr 1;
    {Is the middle item larger than the left item?}
    if LPLeftItem^[0].TotalMemoryUsage > LPLeftItem^[M].TotalMemoryUsage then
    begin
      {Swap items 0 and M}
      LTempItem := LPLeftItem^[0];
      LPLeftItem^[0] := LPLeftItem^[M];
      LPLeftItem^[M] := LTempItem;
    end;
    {Is the middle item larger than the right?}
    if LPLeftItem^[M].TotalMemoryUsage > LPLeftItem^[LRightIndex].TotalMemoryUsage then
    begin
      {The right-hand item is not larger - swap it with the middle}
      LTempItem := LPLeftItem^[LRightIndex];
      LPLeftItem^[LRightIndex] := LPLeftItem^[M];
      LPLeftItem^[M] := LTempItem;
      {Is the left larger than the new middle?}
      if LPLeftItem^[0].TotalMemoryUsage > LPLeftItem^[M].TotalMemoryUsage then
      begin
        {Swap items 0 and M}
        LTempItem := LPLeftItem^[0];
        LPLeftItem^[0] := LPLeftItem^[M];
        LPLeftItem^[M] := LTempItem;
      end;
    end;
    {Move the pivot item out of the way by swapping M with R - 1}
    LPivot := LPLeftItem^[M];
    LPLeftItem^[M] := LPLeftItem^[LRightIndex - 1];
    LPLeftItem^[LRightIndex - 1] := LPivot;
    {Set up the loop counters}
    I := 0;
    J := LRightIndex - 1;
    while True do
    begin
      {Find the first item from the left that is not smaller than the pivot}
      repeat
        Inc(I);
      until LPLeftItem^[I].TotalMemoryUsage >= LPivot.TotalMemoryUsage;
      {Find the first item from the right that is not larger than the pivot}
      repeat
        Dec(J);
      until LPLeftItem^[J].TotalMemoryUsage <= LPivot.TotalMemoryUsage;
      {Stop the loop when the two indexes cross}
      if J < I then
        Break;
      {Swap item I and J}
      LTempItem := LPLeftItem^[I];
      LPLeftItem^[I] := LPLeftItem^[J];
      LPLeftItem^[J] := LTempItem;
    end;
    {Put the pivot item back in the correct position by swapping I with R - 1}
    LPLeftItem^[LRightIndex - 1] := LPLeftItem^[I];
    LPLeftItem^[I] := LPivot;
    {Sort the left-hand partition}
    if J >= (QuickSortMinimumItemsInPartition - 1) then
      QuickSortLogNodes(LPLeftItem, J);
    {Sort the right-hand partition}
    PMemLogNode := @(LPLeftItem[I + 1]);
    LPLeftItem := GetNodeListFromNode(PMemLogNode);
    LRightIndex := LRightIndex - I - 1;
    if LRightIndex < (QuickSortMinimumItemsInPartition - 1) then
      Break;
  end;
end;

{LogMemoryManagerStateToFile subroutine: An InsertionSort routine for sorting a TMemoryLogNodes array.}
procedure InsertionSortLogNodes(APLeftItem: PMemoryLogNodes; ARightIndex: Integer);
var
  I, J: Integer;
  LCurNode: TMemoryLogNode;
begin
  for I := 1 to ARightIndex do
  begin
    LCurNode := APLeftItem^[I];
    {Scan backwards to find the best insertion spot}
    J := I;
    while (J > 0) and (APLeftItem^[J - 1].TotalMemoryUsage > LCurNode.TotalMemoryUsage) do
    begin
      APLeftItem^[J] := APLeftItem^[J - 1];
      Dec(J);
    end;
    APLeftItem^[J] := LCurNode;
  end;
end;

{Writes a log file containing a summary of the memory mananger state and a summary of allocated blocks grouped by
 class. The file will be saved in UTF-8 encoding (in supported Delphi versions). Returns True on success. }
function LogMemoryManagerStateToFile(const AFileName: string; const AAdditionalDetails: string {$IFNDEF FPC}= ''{$ENDIF}): Boolean;
const
  MsgBufferSize = 65536;
  MaxLineLength = 512;
  {Write the UTF-8 BOM in Delphi versions that support UTF-8 conversion.}
  LogStateHeaderMsg = {$IFDEF BCB6OrDelphi7AndUp}#$EF#$BB#$BF + {$ENDIF}
    'FastMM State Capture:'#13#10'---------------------'#13#10#13#10;
  LogStateAllocatedMsg = 'K Allocated'#13#10;
  LogStateOverheadMsg = 'K Overhead'#13#10;
  LogStateEfficiencyMsg = '% Efficiency'#13#10#13#10'Usage Detail:'#13#10;
  LogStateAdditionalInfoMsg = #13#10'Additional Information:'#13#10'-----------------------'#13#10;
  AverageSizeLeadText = ' (';
  AverageSizeTrailingText = ' bytes avg.)'#13#10;
var
  LUMsg,
  LUBuf: NativeUInt;
  LPLogInfo: PMemoryLogInfo;
  LInd: Integer;
  LPNode: PMemoryLogNode;
  LMsgBuffer: array[0..MsgBufferSize - 1] of AnsiChar;
  LPInitialMsgPtr,
  LPMsg: PAnsiChar;
  LBufferSpaceUsed,
  LBytesWritten: Cardinal;
  LFileHandle: THandle; {use NativeUint if THandle is not available}
  LMemoryManagerUsageSummary: TMemoryManagerUsageSummary;
  LUTF8Str: AnsiString;
  LMemLogNode: PMemoryLogNode; {Just to store an interim result. Needed for
                                "typed @ operator", to simplify things and remove
                                typecasts that pose potential dannger.}
  LInitialSize: Cardinal;
  LCallback: TWalkAllocatedBlocksCallback;
begin
  {Get the current memory manager usage summary.}
  FillChar(LMemoryManagerUsageSummary, SizeOf(LMemoryManagerUsageSummary), 0);
  GetMemoryManagerUsageSummary(LMemoryManagerUsageSummary);
  {Allocate the memory required to capture detailed allocation information.}
  LPLogInfo := VirtualAlloc(nil, SizeOf(TMemoryLogInfo), MEM_COMMIT or MEM_TOP_DOWN, PAGE_READWRITE);
  if LPLogInfo <> nil then
  begin
    try
      {Log all allocated blocks by class.}
      LCallback := {$IFDEF FPC}@{$ENDIF}LogMemoryManagerStateCallBack;
      WalkAllocatedBlocks(LCallback, LPLogInfo);
      {Sort the classes by total memory usage: Do the initial QuickSort pass over the list to sort the list in groups
       of QuickSortMinimumItemsInPartition size.}
      if LPLogInfo^.NodeCount >= QuickSortMinimumItemsInPartition then
      begin
        LMemLogNode := @(LPLogInfo^.Nodes[0]);
        QuickSortLogNodes(GetNodeListFromNode(LMemLogNode), LPLogInfo^.NodeCount - 1);
      end;
      {Do the final InsertionSort pass.}
      LMemLogNode := @(LPLogInfo^.Nodes[0]);
      InsertionSortLogNodes(GetNodeListFromNode(LMemLogNode), LPLogInfo^.NodeCount - 1);
      {Create the output file}
      {$IFDEF POSIX}
      lFileHandle := FileCreate(AFilename);
      {$ELSE}
      LFileHandle := CreateFile(PChar(AFilename), GENERIC_READ or GENERIC_WRITE, 0,
        nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
      {$ENDIF}
      if LFileHandle <> INVALID_HANDLE_VALUE then
      begin
        try
          {Log the usage summary}
          LPMsg := @(LMsgBuffer[0]);
          LPInitialMsgPtr := LPMsg;
          LInitialSize := (SizeOf(LMsgBuffer) div SizeOf(LMsgBuffer[0]))-1;
          LPMsg := AppendStringToBuffer(LogStateHeaderMsg, LPMsg, Length(LogStateHeaderMsg), LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
          LPMsg := NativeUIntToStrBuf(LMemoryManagerUsageSummary.AllocatedBytes shr 10, LPMsg, LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
          LPMsg := AppendStringToBuffer(LogStateAllocatedMsg, LPMsg, Length(LogStateAllocatedMsg), LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
          LPMsg := NativeUIntToStrBuf(LMemoryManagerUsageSummary.OverheadBytes shr 10, LPMsg, LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
          LPMsg := AppendStringToBuffer(LogStateOverheadMsg, LPMsg, Length(LogStateOverheadMsg), LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
          LPMsg := NativeUIntToStrBuf(Round(LMemoryManagerUsageSummary.EfficiencyPercentage), LPMsg, LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
          LPMsg := AppendStringToBuffer(LogStateEfficiencyMsg, LPMsg, Length(LogStateEfficiencyMsg), LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
          {Log the allocation detail}
          for LInd := LPLogInfo^.NodeCount - 1 downto 0 do
          begin
            LPNode := @(LPLogInfo^.Nodes[LInd]);
            {Add the allocated size}
            LPMsg^ := ' ';
            Inc(LPMsg);
            LPMsg := NativeUIntToStrBuf(LPNode^.TotalMemoryUsage, LPMsg, LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
            LPMsg := AppendStringToBuffer(BytesMessage, LPMsg, Length(BytesMessage), LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
            {Add the class type}
            case NativeUInt(LPNode^.ClassPtr) of
              {Unknown}
              0:
              begin
                LPMsg := AppendStringToBuffer(UnknownClassNameMsg, LPMsg, Length(UnknownClassNameMsg), LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
              end;
              {AnsiString}
              1:
              begin
                LPMsg := AppendStringToBuffer(AnsiStringBlockMessage, LPMsg, Length(AnsiStringBlockMessage), LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
              end;
              {UnicodeString}
              2:
              begin
                LPMsg := AppendStringToBuffer(UnicodeStringBlockMessage, LPMsg, Length(UnicodeStringBlockMessage), LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
              end;
              {Classes}
            else
              begin
                LPMsg := AppendClassNameToBuffer(LPNode^.ClassPtr, LPMsg, LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
              end;
            end;
            {Add the count}
            LPMsg^ := ' ';
            Inc(LPMsg);
            LPMsg^ := 'x';
            Inc(LPMsg);
            LPMsg^ := ' ';
            Inc(LPMsg);
            LPMsg := NativeUIntToStrBuf(LPNode^.InstanceCount, LPMsg, LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
            LPMsg := AppendStringToBuffer(AverageSizeLeadText, LPMsg, Length(AverageSizeLeadText), LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
            LPMsg := NativeUIntToStrBuf(LPNode^.TotalMemoryUsage div LPNode^.InstanceCount, LPMsg, LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
            LPMsg := AppendStringToBuffer(AverageSizeTrailingText, LPMsg, Length(AverageSizeTrailingText), LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
            {Flush the buffer?}
            LUMsg := NativeUInt(LPMsg);
            LUBuf := NativeUInt(@LMsgBuffer);
            if LUMsg > LUBuf then
            begin
              LBufferSpaceUsed := LUMsg - LUBuf;
              if LBufferSpaceUsed > (MsgBufferSize - MaxLineLength) then
              begin
                LBytesWritten := 0;
                WriteFile(LFileHandle, LMsgBuffer, LBufferSpaceUsed, LBytesWritten, nil);
                LPMsg := @(LMsgBuffer[0]);
              end;
            end;
          end;
          if AAdditionalDetails <> '' then
          begin
            LPMsg := AppendStringToBuffer(LogStateAdditionalInfoMsg, LPMsg, Length(LogStateAdditionalInfoMsg), LInitialSize-NativeUInt(LPMsg-LPInitialMsgPtr));
          end;
          {Flush any remaining bytes}
          LUMsg := NativeUInt(LPMsg);
          LUBuf := NativeUInt(@LMsgBuffer);
          if LUMsg > LUBuf then
          begin
            LBufferSpaceUsed :=  LUMsg - LUBuf;
            WriteFile(LFileHandle, LMsgBuffer, LBufferSpaceUsed, LBytesWritten, nil);
          end;
          {Write the additional info}
          if AAdditionalDetails <> '' then
          begin
            {$IFDEF BCB6OrDelphi7AndUp}
            LUTF8Str := UTF8Encode(AAdditionalDetails);
            {$ELSE}
            LUTF8Str := AAdditionalDetails;
            {$ENDIF}
            if Length(LUTF8Str) > 0 then
            begin
              WriteFile(LFileHandle, PAnsiChar(LUTF8Str)^, Length(LUTF8Str), LBytesWritten, nil);
            end;
          end;
          {Success}
          Result := True;
        finally
          {Close the file}
          {$IFDEF POSIX}
            {$IFNDEF fpc}
          __close(LFileHandle)
            {$ELSE}
          fpclose(LFileHandle)
            {$ENDIF}
          {$ELSE}
          CloseHandle(LFileHandle);
          {$ENDIF}
        end;
      end
      else
        Result := False;
    finally
      VirtualFree(LPLogInfo, 0, MEM_RELEASE);
    end;
  end
  else
    Result := False;
end;

end.
