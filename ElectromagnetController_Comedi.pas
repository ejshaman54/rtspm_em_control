unit ComediLL;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ctypes, dynlibs;

type
  Pcomedi_t = Pointer;
  Pcomedi_range = ^comedi_range;
  comedi_range = record
    min, max: Double; // physical units (V for analog)
    unit_: cint;
  end;

const
  LIBCOMEDI = 'libcomedi.so';
  AREF_GROUND = 0;
  AREF_COMMON = 1;
  AREF_DIFF   = 2;
  AREF_OTHER  = 3;

type
  TComediDevice = class
  private
    FDev: Pcomedi_t;
    FAO_Subdev, FAI_Subdev: cint;
    FAO_Range, FAI_Range: cint;
    FAO_MaxData, FAI_MaxData: culong;
    FAO_ARef, FAI_ARef: cint;
    function GetRange(Subdev, Chan, RangeIdx: cint): comedi_range;
  public
    constructor Create(const DevName: AnsiString;
                       AO_Subdev, AI_Subdev: cint;
                       AO_Range, AI_Range: cint;
                       AO_ARef: cint = AREF_GROUND; AI_ARef: cint = AREF_GROUND);
    destructor Destroy; override;
    procedure AO_WriteVolts(Chan: cint; Volts: Double);
    function  AI_ReadVolts(Chan: cint): Double;
  end;

implementation

type
  Tcomedi_open = function(filename: PChar): Pcomedi_t; cdecl;
  Tcomedi_close = function(dev: Pcomedi_t): cint; cdecl;
  Tcomedi_get_maxdata = function(dev: Pcomedi_t; subdevice, chan: cuint): culong; cdecl;
  Tcomedi_get_range = function(dev: Pcomedi_t; subdevice, chan, range: cuint): Pcomedi_range; cdecl;
  Tcomedi_data_write = function(dev: Pcomedi_t; subdevice, chan, range, aref: cuint; data: culong): cint; cdecl;
  Tcomedi_data_read = function(dev: Pcomedi_t; subdevice, chan, range, aref: cuint; var data: culong): cint; cdecl;
  Tcomedi_from_physical = function(physical_value: Double; rng: Pcomedi_range; maxdata: culong): culong; cdecl;
  Tcomedi_to_physical = function(data: culong; rng: Pcomedi_range; maxdata: culong): Double; cdecl;

var
  hComedi: TLibHandle = 0;
  comedi_open: Tcomedi_open;
  comedi_close: Tcomedi_close;
  comedi_get_maxdata: Tcomedi_get_maxdata;
  comedi_get_range: Tcomedi_get_range;
  comedi_data_write: Tcomedi_data_write;
  comedi_data_read: Tcomedi_data_read;
  comedi_from_physical: Tcomedi_from_physical;
  comedi_to_physical: Tcomedi_to_physical;

procedure Need(cond: Boolean; const Msg: String);
begin
  if not cond then raise Exception.Create(Msg);
end;

function LoadSym(const Sym: PChar): Pointer;
begin
  Result := GetProcAddress(hComedi, Sym);
  Need(Assigned(Result), 'Missing symbol in libcomedi: ' + String(Sym));
end;

function LoadLibIfNeeded: Boolean;
begin
  if hComedi <> 0 then Exit(True);
  hComedi := LoadLibrary(LIBCOMEDI);
  if hComedi = 0 then Exit(False);
  Pointer(comedi_open) := LoadSym('comedi_open');
  Pointer(comedi_close) := LoadSym('comedi_close');
  Pointer(comedi_get_maxdata) := LoadSym('comedi_get_maxdata');
  Pointer(comedi_get_range) := LoadSym('comedi_get_range');
  Pointer(comedi_data_write) := LoadSym('comedi_data_write');
  Pointer(comedi_data_read) := LoadSym('comedi_data_read');
  Pointer(comedi_from_physical) := LoadSym('comedi_from_physical');
  Pointer(comedi_to_physical) := LoadSym('comedi_to_physical');
  Result := True;
end;

constructor TComediDevice.Create(const DevName: AnsiString;
  AO_Subdev, AI_Subdev, AO_Range, AI_Range: cint; AO_ARef, AI_ARef: cint);
begin
  inherited Create;
  Need(LoadLibIfNeeded, 'Cannot load ' + LIBCOMEDI);
  FDev := comedi_open(PChar(DevName));
  Need(FDev <> nil, 'comedi_open failed on ' + String(DevName));
  FAO_Subdev := AO_Subdev; FAI_Subdev := AI_Subdev;
  FAO_Range := AO_Range;   FAI_Range := AI_Range;
  FAO_ARef := AO_ARef;     FAI_ARef := AI_ARef;
  // maxdata depends on channel; we’ll query per-call or assume chan 0 for cache
  FAO_MaxData := comedi_get_maxdata(FDev, FAO_Subdev, 0);
  FAI_MaxData := comedi_get_maxdata(FDev, FAI_Subdev, 0);
  Need(FAO_MaxData > 0, 'AO maxdata invalid');
  Need(FAI_MaxData > 0, 'AI maxdata invalid');
end;

destructor TComediDevice.Destroy;
begin
  if (FDev <> nil) then comedi_close(FDev);
  inherited Destroy;
end;

function TComediDevice.GetRange(Subdev, Chan, RangeIdx: cint): comedi_range;
var p: Pcomedi_range;
begin
  p := comedi_get_range(FDev, Subdev, Chan, RangeIdx);
  Need(p <> nil, 'comedi_get_range failed');
  Result := p^;
end;

procedure TComediDevice.AO_WriteVolts(Chan: cint; Volts: Double);
var rng: comedi_range; data: culong; maxd: culong;
begin
  rng := GetRange(FAO_Subdev, Chan, FAO_Range);
  // clamp to physical range
  if Volts < rng.min then Volts := rng.min;
  if Volts > rng.max then Volts := rng.max;
  maxd := comedi_get_maxdata(FDev, FAO_Subdev, Chan);
  data := comedi_from_physical(Volts, @rng, maxd);
  Need(comedi_data_write(FDev, FAO_Subdev, Chan, FAO_Range, FAO_ARef, data) = 1,
      'comedi_data_write failed');
end;

function TComediDevice.AI_ReadVolts(Chan: cint): Double;
var rng: comedi_range; data, ok: culong; maxd: culong;
begin
  rng := GetRange(FAI_Subdev, Chan, FAI_Range);
  ok := comedi_data_read(FDev, FAI_Subdev, Chan, FAI_Range, FAI_ARef, data);
  Need(ok = 1, 'comedi_data_read failed');
  maxd := comedi_get_maxdata(FDev, FAI_Subdev, Chan);
  Result := comedi_to_physical(data, @rng, maxd);
end;

end.
