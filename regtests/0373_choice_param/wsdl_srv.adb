------------------------------------------------------------------------------
--                              Ada Web Server                              --
--                                                                          --
--                       Copyright (C) 2025, AdaCore                        --
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
with Ada.Strings.Unbounded;

with AWS.MIME;
with SOAP.Message.Response.Error;

with WSDL_Choice.Server;
with WSDL_Choice.Types;

package body WSDL_Srv is

   use Ada.Text_IO;

   procedure Try (Param1 : WSDL_Choice.Types.tns_Status_Type);

   ---------
   -- Try --
   ---------

   procedure Try
     (Param1 : WSDL_Choice.Types.tns_Status_Type) is
   begin
      New_Line;
      Put_Line ("Param1: " & Param1'Image);
   end Try;

   function Try_CB is new WSDL_Choice.Server.Try_CB (Try);

   -------------
   -- HTTP_CB --
   -------------

   function HTTP_CB (Request : Status.Data) return Response.Data is
   begin
      return Response.Build
        (MIME.Text_HTML, "No HTTP request should be called.");
   end HTTP_CB;

   -------------
   -- SOAP_CB --
   -------------

   function SOAP_CB
     (SOAPAction : String;
      Payload    : Message.Payload.Object;
      Request    : Status.Data)
      return Response.Data is
   begin
      if SOAPAction = "Try" then
         return Try_CB (SOAPAction, Payload, Request);

      else
         return Message.Response.Build
           (Message.Response.Error.Build
              (Message.Response.Error.Client,
               "Wrong SOAP action " & SOAPAction));
      end if;
   end SOAP_CB;

end WSDL_Srv;
