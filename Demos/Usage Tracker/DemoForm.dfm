object FormDemo: TFormDemo
  Left = 199
  Top = 114
  BorderIcons = [biSystemMenu]
  BorderStyle = bsSingle
  Caption = 'Usage Tracker Demo'
  ClientHeight = 186
  ClientWidth = 239
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'MS Sans Serif'
  Font.Style = []
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 13
  object BtnShowTracker: TButton
    Left = 8
    Top = 139
    Width = 221
    Height = 37
    Caption = 'Show Usage Tracker'
    TabOrder = 0
    OnClick = BtnShowTrackerClick
  end
  object BtnReserveSmall: TButton
    Left = 8
    Top = 10
    Width = 221
    Height = 37
    Caption = 'Reserve small blocks'
    TabOrder = 1
    OnClick = BtnReserveSmallClick
  end
  object BtnReserveMedium: TButton
    Left = 8
    Top = 53
    Width = 221
    Height = 37
    Caption = 'Reserve medium blocks'
    TabOrder = 2
    OnClick = BtnReserveMediumClick
  end
  object BtnReserveLarge: TButton
    Left = 8
    Top = 96
    Width = 221
    Height = 37
    Caption = 'Reserve large block'
    TabOrder = 3
    OnClick = BtnReserveLargeClick
  end
end
