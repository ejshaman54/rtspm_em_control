unit ElectromagnetController_Comedi;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, ComediLL;

type
  IMagnetBackend = interface
    procedure EnableOutput(Enable: Boolean);
    procedure SetCurrentSetpoint(Amp: Double);
    function  ReadCurrent: Double;
    function  ReadVoltage: Double;
    function  IsOK: Boolean;
  end;

  { Analog-programmed supply via Comedi AO/AI }
  TComediAnalogMagnet = class(TInterfacedObject, IMagnetBackend)
  private
    FDev: TComediDevice;
    FAOChan, FAIChan: Integer;
    FAVPerAmp: Double; // V/A for program input (e.g., 0.2 V/A)
    FMonitorVPerAmp: Double; // V/A for monitor output (often same; set if different)
    FEnabled: Boolean;
  public
    constructor Create(const DevName: AnsiString;
                       AO_Subdev, AO_Chan, AO_Range: Integer;
                       AI_Subdev, AI_Chan, AI_Range: Integer;
                       AVPerAmp, MonitorVPerAmp: Double);
    destructor Destroy; override;
    procedure EnableOutput(Enable: Boolean);
    procedure SetCurrentSetpoint(Amp: Double);
    function  ReadCurrent: Double;
    function  ReadVoltage: Double;
    function  IsOK: Boolean;
  end;

  { High-level controller with ramp thread }
  TElectromagnetController = class(TThread)
  private
    FBackend: IMagnetBackend;
    FTargetA: Double;
    FCurrentA: Double;
    FRampAps: Double;
    FMaxA: Double;
    FRun: Boolean;
    FLock: TCriticalSection;
  protected
    procedure Execute; override;
  public
    constructor Create(Backend: IMagnetBackend);
    destructor Destroy; override;
    procedure StartControl;
    procedure StopControl;
    procedure SetRampRate(Aps: Double);
    procedure SetMaxCurrent(A: Double);
    procedure Enable(En: Boolean);
    procedure SetSetpointA(A: Double);
    function  ReadbackA: Double;
    function  ReadbackV: Double;
  end;

implementation

uses Math;

{ TComediAnalogMagnet }

constructor TComediAnalogMagnet.Create(const DevName: AnsiString;
  AO_Subdev, AO_Chan, AO_Range: Integer;
  AI_Subdev, AI_Chan, AI_Range: Integer;
  AVPerAmp, MonitorVPerAmp: Double);
begin
  inherited Create;
  FDev := TComediDevice.Create(DevName, AO_Subdev, AI_Subdev, AO_Range, AI_Range);
  FAOChan := AO_Chan; FAIChan := AI_Chan;
  FAVPerAmp := AVPerAmp;
  if MonitorVPerAmp > 0 then FMonitorVPerAmp := MonitorVPerAmp
  else FMonitorVPerAmp := AVPerAmp;
  FEnabled := False;
  // default to 0 V output
  FDev.AO_WriteVolts(FAOChan, 0.0);
end;

destructor TComediAnalogMagnet.Destroy;
begin
  try
    FDev.AO_WriteVolts(FAOChan, 0.0);
  except end;
  FDev.Free;
  inherited Destroy;
end;

procedure TComediAnalogMagnet.EnableOutput(Enable: Boolean);
begin
  FEnabled := Enable;
  if not Enable then
    FDev.AO_WriteVolts(FAOChan, 0.0);
end;

procedure TComediAnalogMagnet.SetCurrentSetpoint(Amp: Double);
var volts: Double;
begin
  if not FEnabled then Exit;
  volts := Amp * FAVPerAmp; // V = I * (V/A)
  FDev.AO_WriteVolts(FAOChan, volts);
end;

function TComediAnalogMagnet.ReadCurrent: Double;
var vmon: Double;
begin
  vmon := ReadVoltage;
  Result := vmon / FMonitorVPerAmp;
end;

function TComediAnalogMagnet.ReadVoltage: Double;
begin
  Result := FDev.AI_ReadVolts(FAIChan);
end;

function TComediAnalogMagnet.IsOK: Boolean;
begin
  // If you wire an interlock to a DI line, check it here.
  Result := True;
end;

{ TElectromagnetController }

constructor TElectromagnetController.Create(Backend: IMagnetBackend);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FBackend := Backend;
  FTargetA := 0.0;
  FCurrentA := 0.0;
  FRampAps := 0.5; // A/s default
  FMaxA := 10.0;   // clamp
  FRun := False;
  FLock := TCriticalSection.Create;
end;

destructor TElectromagnetController.Destroy;
begin
  StopControl;
  FLock.Free;
  inherited Destroy;
end;

procedure TElectromagnetController.StartControl;
begin
  if not FRun then begin
    FRun := True;
    Resume;
  end;
end;

procedure TElectromagnetController.StopControl;
begin
  FRun := False;
  WaitFor;
end;

procedure TElectromagnetController.SetRampRate(Aps: Double);
begin
  FLock.Acquire;
  try FRampAps := Max(1e-3, Aps);
  finally FLock.Release; end;
end;

procedure TElectromagnetController.SetMaxCurrent(A: Double);
begin
  FLock.Acquire;
  try FMaxA := Abs(A);
  finally FLock.Release; end;
end;

procedure TElectromagnetController.Enable(En: Boolean);
begin
  FBackend.EnableOutput(En);
end;

procedure TElectromagnetController.SetSetpointA(A: Double);
begin
  FLock.Acquire;
  try FTargetA := EnsureRange(A, -FMaxA, FMaxA);
  finally FLock.Release; end;
end;

function TElectromagnetController.ReadbackA: Double;
begin
  Result := FBackend.ReadCurrent;
end;

function TElectromagnetController.ReadbackV: Double;
begin
  Result := FBackend.ReadVoltage;
end;

procedure TElectromagnetController.Execute;
const dt = 0.05; // seconds
var stepA: Double; target: Double;
begin
  while FRun do begin
    if not FBackend.IsOK then begin
      FBackend.EnableOutput(False);
      Exit;
    end;
    FLock.Acquire;
    try target := FTargetA; stepA := FRampAps * dt; finally FLock.Release; end;

    if Abs(target - FCurrentA) <= stepA then
      FCurrentA := target
    else if target > FCurrentA then
      FCurrentA := FCurrentA + stepA
    else
      FCurrentA := FCurrentA - stepA;

    FBackend.SetCurrentSetpoint(FCurrentA);
    Sleep(Round(dt*1000));
  end;
  // ramped thread stopping—ensure output is left at current setpoint (or 0 if disabled)
end;

end.
