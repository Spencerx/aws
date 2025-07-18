------------------------------------------------------------------------------
--                              Ada Web Server                              --
--                                                                          --
--                     Copyright (C) 2017-2025, AdaCore                     --
--                                                                          --
--  This is free software;  you can redistribute it  and/or modify it       --
--  under terms of the  GNU General Public License as published  by the     --
--  Free Software  Foundation;  either version 3,  or (at your option) any  --
--  later version.  This software is distributed in the hope  that it will  --
--  be useful, but WITHOUT ANY WARRANTY;  without even the implied warranty --
--  of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU     --
--  General Public License for  more details.                               --
--                                                                          --
--  You should have  received  a copy of the GNU General  Public  License   --
--  distributed  with  this  software;   see  file COPYING3.  If not, go    --
--  to http://www.gnu.org/licenses for a complete copy of the license.      --
------------------------------------------------------------------------------

pragma Ada_2022;

with Ada.Text_IO;

with AWS;
with AWS.Config.Set;
with AWS.Response;
with AWS.Server.Status;
with AWS.Status;
with SOAP.Dispatchers.Callback;

with Array_Rec_Enum_Data_Service.CB;
with Array_Rec_Enum_Data_Service.Client;
with Array_Rec_Enum_Data_Service.Server;
with Array_Rec_Enum_Data_Service.Types;

with Array_Rec_Enum_Types;

procedure Array_Rec_Enum_Main is

   use Ada;
   use Array_Rec_Enum_Data_Service.Client;
   use Array_Rec_Enum_Data_Service.Types;

   package ARIT renames Array_Rec_Enum_Types;

   use AWS;

   function CB (Request : Status.Data) return Response.Data is
      R : Response.Data;
   begin
      return R;
   end CB;

   WS   : AWS.Server.HTTP;
   Conf : Config.Object;
   Disp : Array_Rec_Enum_Data_Service.CB.Handler;

begin
   Config.Set.Server_Host (Conf, "localhost");
   Config.Set.Server_Port (Conf, 0);

   Disp := SOAP.Dispatchers.Callback.Create
     (CB'Unrestricted_Access,
      Array_Rec_Enum_Data_Service.CB.SOAP_CB'Access,
      Array_Rec_Enum_Data_Service.Schema);

   AWS.Server.Start (WS, Disp, Conf);

   declare
      A : constant ARIT.Enum_List_Type_Pkg.Vector :=
            [ARIT.One, ARIT.Three, ARIT.Two];
      L : ARIT.Array_Enum_Type := (Value => A);
   begin
      Test_Array (L, Endpoint => Server.Status.Local_URL (WS));
   end;

   declare
      A : constant ARIT.Enum_List_Type_Pkg.Vector :=
            [ARIT.One, ARIT.Three, ARIT.Two];
   begin
      Test_List (A, Endpoint => Server.Status.Local_URL (WS));
   end;

   declare
      A : constant ARIT.Enum_List_Type_Pkg.Vector :=
            [ARIT.One, ARIT.Three, ARIT.Two];
      L : ARIT.Array_Enum_Type := (Value => A);
   begin
      Test_AL (L, A, Endpoint => Server.Status.Local_URL (WS));
   end;

   AWS.Server.Shutdown (WS);
end Array_Rec_Enum_Main;
