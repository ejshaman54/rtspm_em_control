uses ElectromagnetController_Comedi;

var
  MagBackend: IMagnetBackend;
  Magnet: TElectromagnetController;

procedure TMainForm.InitMagnet;
const
  DEV         = '/dev/comedi0';
  AO_SUBDEV   = 1;   AO_CHAN = 0;   AO_RANGE = 0;  // check with comedi_test
  AI_SUBDEV   = 0;   AI_CHAN = 0;   AI_RANGE = 0;  // check with comedi_test
  AV_PER_AMP  = 0.2; // example: 0–10 V → 0–50 A
  MON_V_PER_A = 0.2; // monitor scaling (set if different)
begin
  MagBackend := TComediAnalogMagnet.Create(
                 DEV, AO_SUBDEV, AO_CHAN, AO_RANGE,
                 AI_SUBDEV, AI_CHAN, AI_RANGE,
                 AV_PER_AMP, MON_V_PER_A);

  Magnet := TElectromagnetController.Create(MagBackend);
  Magnet.SetMaxCurrent(50.0); // clamp to your supply limit
  Magnet.SetRampRate(1.0);    // A/s
  Magnet.StartControl;
end;

procedure TMainForm.BtnMagEnableClick(Sender: TObject);
begin
  Magnet.Enable(True);
end;

procedure TMainForm.BtnMagDisableClick(Sender: TObject);
begin
  Magnet.Enable(False);
end;

procedure TMainForm.BtnSetCurrentClick(Sender: TObject);
begin
  // from a numeric edit control
  Magnet.SetSetpointA(SpinEditSetpoint.Value);
end;

procedure TMainForm.TimerMagReadbackTimer(Sender: TObject);
begin
  LabelI.Caption := Format('I = %.3f A', [Magnet.ReadbackA]);
  LabelV.Caption := Format('Vmon = %.3f V', [Magnet.ReadbackV]);
end;
