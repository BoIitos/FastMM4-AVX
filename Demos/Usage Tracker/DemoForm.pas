unit DemoForm;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls, FastMMUsageTracker;

type

  TFormDemo = class(TForm)
    BtnShowTracker: TButton;
    BtnReserveSmall: TButton;
    BtnReserveMedium: TButton;
    BtnReserveLarge: TButton;
    procedure BtnShowTrackerClick(Sender: TObject);
    procedure BtnReserveSmallClick(Sender: TObject);
    procedure BtnReserveMediumClick(Sender: TObject);
    procedure BtnReserveLargeClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FReservedMem: Array[1..3] of TList;
  public
    { Public declarations }
  end;

var
  FormDemo: TFormDemo;

implementation

{$R *.dfm}

procedure TFormDemo.BtnShowTrackerClick(Sender: TObject);
begin
  ShowFastMMUsageTracker;
end;

procedure TFormDemo.FormCreate(Sender: TObject);
var
  i: Integer;
begin
  for i:=1 to 3 do
  begin
    FReservedMem[i]:=TList.Create;
  end;
end;

procedure TFormDemo.FormDestroy(Sender: TObject);
var
  i,j: Integer;
begin
  for i:=1 to 3 do
  begin
    for j:=0 to FReservedMem[i].Count-1 do
    begin
      FreeMem(FReservedMem[i][j]);
    end;
    FReservedMem[i].Free;
  end;
end;

procedure TFormDemo.BtnReserveLargeClick(Sender: TObject);
var
  P: Pointer;
begin
  GetMem(P,10000000);
  FReservedMem[3].Add(P);
end;

procedure TFormDemo.BtnReserveMediumClick(Sender: TObject);
var
  P: Pointer;
begin
  for var Loop:=1 to 100 do
  begin
    GetMem(P,100000);
    FReservedMem[2].Add(P);
  end;
end;

procedure TFormDemo.BtnReserveSmallClick(Sender: TObject);
var
  P: Pointer;
begin
  for var Loop:=1 to 100000 do
  begin
    GetMem(P,100);
    FReservedMem[1].Add(P);
  end;
end;

end.
