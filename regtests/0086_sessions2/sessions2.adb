------------------------------------------------------------------------------
--                              Ada Web Server                              --
--                                                                          --
--                     Copyright (C) 2003-2008, AdaCore                     --
--                                                                          --
--  This library is free software; you can redistribute it and/or modify    --
--  it under the terms of the GNU General Public License as published by    --
--  the Free Software Foundation; either version 2 of the License, or (at   --
--  your option) any later version.                                         --
--                                                                          --
--  This library is distributed in the hope that it will be useful, but     --
--  WITHOUT ANY WARRANTY; without even the implied warranty of              --
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU       --
--  General Public License for more details.                                --
--                                                                          --
--  You should have received a copy of the GNU General Public License       --
--  along with this library; if not, write to the Free Software Foundation, --
--  Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.          --
--                                                                          --
--  As a special exception, if other files instantiate generics from this   --
--  unit, or you link this unit with other files to produce an executable,  --
--  this  unit  does not  by itself cause  the resulting executable to be   --
--  covered by the GNU General Public License. This exception does not      --
--  however invalidate any other reasons why the executable file  might be  --
--  covered by the  GNU Public License.                                     --
------------------------------------------------------------------------------

with Ada.Calendar;
with Ada.Exceptions;
with Ada.Text_IO;

with AWS.Client;
with AWS.Config.Set;
with AWS.MIME;
with AWS.Parameters;
with AWS.Response;
with AWS.Server;
with AWS.Session;
with AWS.Status;
with AWS.Utils;

with Get_Free_Port;

procedure Sessions2 is

   use Ada;
   use AWS;

   WS   : Server.HTTP;
   Port : Natural := 1256;

   task type T_Client is
      entry Start (N : in Positive);
      entry Stopped;
   end T_Client;

   task Server is
      entry Start;
      entry Started;
      entry Stop;
   end Server;

   Clients : array (1 .. 5) of T_Client;

   --------
   -- CB --
   --------

   function CB (Request : in Status.Data) return Response.Data is
      SID : constant Session.ID      := Status.Session (Request);
      Key : constant String := "key";
      N   : Natural := 0;
   begin
      if Session.Exist (SID, Key) then
         N := Session.Get (SID, Key);
         N := N + 1;
      end if;

      Session.Set (SID, Key, N);

      return Response.Build
        (MIME.Text_HTML, "Ok, this is call " & Natural'Image (N));
   end CB;

   --------------
   -- T_Client --
   --------------

   task body T_Client is
      R : Response.Data;
      C : Client.HTTP_Connection;
      N : Positive;
   begin
      accept Start (N : in Positive) do
         T_Client.N := N;
      end Start;

      Client.Create (C, "http://localhost:" & Utils.Image (Port));

      for K in 1 .. 10 loop
         Client.Get (C, R, "/");
         delay 0.1;
      end loop;

      accept Stopped;

      Client.Close (C);

   exception
      when E : others =>
         Text_IO.Put_Line (Exceptions.Exception_Information (E));
   end T_Client;

   ------------
   -- Server --
   ------------

   task body Server is
   begin
      Get_Free_Port (Port);

      accept Start;

      AWS.Server.Start
        (WS, "session",
         CB'Unrestricted_Access,
         Port           => Port,
         Max_Connection => 5,
         Session        => True);

      accept Started;

      Ada.Text_IO.Put_Line ("started");

      accept Stop;

      Ada.Text_IO.Put_Line ("Ready to stop");
   end Server;

   ----------------
   -- Delete_SID --
   ----------------

   procedure Delete_SID (SID : in Session.ID) is

      procedure Display_Session_Data
        (N          : in     Positive;
         Key, Value : in     String;
         Quit       : in out Boolean) is
      begin
         Text_IO.Put_Line ("   " & Key & " = " & Value);
      end Display_Session_Data;

      procedure Display_Data is
         new Session.For_Every_Session_Data (Display_Session_Data);

   begin
      Text_IO.Put_Line ("New SID");
      Display_Data (SID);
   end Delete_SID;

begin
   Config.Set.Session_Cleanup_Interval (3.0);
   Config.Set.Session_Lifetime (2.0);

   Server.Start;
   Server.Started;

   Session.Set_Callback (Delete_SID'Unrestricted_Access);

   for K in Clients'Range loop
      Clients (K).Start (K);
   end loop;

   delay 1.0;

   for K in Clients'Range loop
      Clients (K).Stopped;
   end loop;

   delay 5.0;

   Session.Set_Callback (null);

   Server.Stop;

   AWS.Server.Shutdown (WS);

   Session.Clear;
   Ada.Text_IO.Put_Line ("shutdown");
end Sessions2;