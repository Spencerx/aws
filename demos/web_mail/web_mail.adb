------------------------------------------------------------------------------
--                              Ada Web Server                              --
--                                                                          --
--                     Copyright (C) 2003-2012, AdaCore                     --
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

--  This is a demo for the Web Mail AWS's feature

with Ada.Text_IO;

with AWS.Server;

with AWS.Services.Web_Mail;

procedure Web_Mail is

   use Ada;

   WS : AWS.Server.HTTP;

begin
   Text_IO.Put_Line ("AWS " & AWS.Version);
   Text_IO.New_Line;

   AWS.Server.Start
     (WS, "Web Mail Demo",
      Port     => 1234,
      Session  => True,
      Callback => AWS.Services.Web_Mail.Callback'Access);

   Text_IO.Put_Line ("Press 'Q' key to shutdown...");

   AWS.Server.Wait (AWS.Server.Q_Key_Pressed);

   AWS.Server.Shutdown (WS);
end Web_Mail;
