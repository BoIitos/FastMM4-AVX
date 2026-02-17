program UsageTrackerDemo;

uses
  FastMM4,
  Forms,
  DemoForm in 'DemoForm.pas' {FormDemo};

{$R *.res}

{Enable large address space support for this demo}
{$SetPEFlags $20}

begin
  Application.Initialize;
  Application.CreateForm(TFormDemo, FormDemo);
  Application.Run;
end.
