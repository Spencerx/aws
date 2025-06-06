------------------------------------------------------------------------------
--                              Ada Web Server                              --
--                                                                          --
--                     Copyright (C) 2005-2024, AdaCore                     --
--                                                                          --
--  This library is free software;  you can redistribute it and/or modify   --
--  it under terms of the  GNU General Public License  as published by the  --
--  Free Software  Foundation;  either version 3,  or (at your  option) any --
--  later version. This library is distributed in the hope that it will be  --
--  useful, but WITHOUT ANY WARRANTY;  without even the implied warranty of --
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.                    --
--                                                                          --
--  As a special exception under Section 7 of GPL version 3, you are        --
--  granted additional permissions described in the GCC Runtime Library     --
--  Exception, version 3.1, as published by the Free Software Foundation.   --
--                                                                          --
--  You should have received a copy of the GNU General Public License and   --
--  a copy of the GCC Runtime Library Exception along with this program;    --
--  see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see   --
--  <http://www.gnu.org/licenses/>.                                         --
--                                                                          --
--  As a special exception, if other files instantiate generics from this   --
--  unit, or you link this unit with other files to produce an executable,  --
--  this  unit  does not  by itself cause  the resulting executable to be   --
--  covered by the GNU General Public License. This exception does not      --
--  however invalidate any other reasons why the executable file  might be  --
--  covered by the  GNU Public License.                                     --
------------------------------------------------------------------------------

with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNAT.MD5;
with GNAT.OS_Lib;
with GNAT.Regexp;

with AWS.Digest;
with AWS.Dispatchers;
with AWS.Headers.Values;
with AWS.Hotplug;
with AWS.HTTP2;
with AWS.Log;
with AWS.Messages;
with AWS.MIME;
with AWS.Net;
with AWS.Net.Buffered;
with AWS.Net.WebSocket.Handshake_Error;
with AWS.Net.WebSocket.Protocol.Draft76;
with AWS.Net.WebSocket.Protocol.RFC6455;
with AWS.Net.WebSocket.Registry.Utils;
with AWS.Parameters;
with AWS.Response.Set;
with AWS.Server.Get_Status;
with AWS.Session;
with AWS.Status.Set;
with AWS.Templates;
with AWS.Translator;
with AWS.URL;
with AWS.Utils;

package body AWS.Server.HTTP_Utils is

   use Ada.Strings;
   use Ada.Strings.Unbounded;

   protected File_Upload_UID is
      procedure Get (ID : out Natural);
      --  returns a UID for file upload. This is to ensure that files
      --  coming from clients will always have different name.
   private
      UID : Natural := 0;
   end File_Upload_UID;

   ----------------------
   -- Answer_To_Client --
   ----------------------

   procedure Answer_To_Client
     (HTTP_Server  : in out AWS.Server.HTTP;
      Line_Index   : Positive;
      C_Stat       : in out AWS.Status.Data;
      Socket_Taken : in out Boolean;
      Will_Close   : in out Boolean)
   is
      use type Messages.Status_Code;

      Answer     : Response.Data := Build_Answer (HTTP_Server, C_Stat);
      Need_Purge : Boolean       := False;

   begin
      if Response.Is_Continue (Answer)
        and then not Status.Is_Body_Uploaded (C_Stat)
      then
         --  Upload message body and call user dispatcher again

         Get_Message_Data
           (HTTP_Server, Line_Index, C_Stat,
            Expect_100 => Status.Expect (C_Stat) = Messages.S100_Continue);

         Answer := Call_For_Dispatcher (HTTP_Server, C_Stat);

      elsif HTTP_Server.Slots.Phase (Line_Index) = Client_Data then
         --  User callback did not read clients message body. If client do not
         --  support 100 (Continue) response, we have to close
         --  socket to discard pending client data.

         Need_Purge := Status.Expect (C_Stat) /= Messages.S100_Continue;

         if not Will_Close then
            Will_Close := Need_Purge;
         end if;

         if Response.Status_Code (Answer) < Messages.S300 then
            Log.Write
              (HTTP_Server.Error_Log,
               C_Stat,
               "User does not upload server data but return status "
               & Messages.Image (Response.Status_Code (Answer)));
         end if;
      end if;

      Send (Answer, HTTP_Server, Line_Index, C_Stat, Socket_Taken, Will_Close);

      if Need_Purge then
         --  User callback did not read client data and client does not support
         --  100 (Continue) response. We need clear socket input buffers to be
         --  able to close socket gracefully.

         declare
            use Ada.Real_Time;
            Socket : constant Net.Socket_Type'Class := Status.Socket (C_Stat);
            Buffer : Stream_Element_Array (1 .. 4096);
            Last   : Stream_Element_Offset;
            Length : Stream_Element_Count := Status.Content_Length (C_Stat);
            Stamp  : constant Time := Clock;
            Span   : constant Time_Span :=
                       To_Time_Span
                         (CNF.Receive_Timeout (HTTP_Server.Properties));
            --  To do not spend too much time on wrong working clients
            Agent  : constant String := Status.User_Agent (C_Stat);
            Fully  : constant Boolean :=
                       Fixed.Index (Agent, "Firefox/") > 0
                         or else Fixed.Index (Agent, "konqueror/") > 0;
            --  JavaScript engine of some browsers does not read the server
            --  responce until successfully send the whole message body.
            --  So we have to read the whole body to let them chance to read
            --  the server answer.
            --  Tested for Firefox/43.0 and konqueror/4.14.9.
            --  Does not need this trick:
            --  OPR/32.0.1948.69 - Opera
            --  Midori/0.5
            --  Chrome/47.0.2526.106
         begin
            while (Fully and then Length > 0 and then Stamp - Clock <= Span)
              or else Socket.Pending > 0
            loop
               Socket.Receive (Buffer, Last);
               Length := Length - Stream_Element_Count (Last);
            end loop;
         end;
      end if;
   end Answer_To_Client;

   ------------------
   -- Build_Answer --
   ------------------

   function Build_Answer
     (HTTP_Server : in out AWS.Server.HTTP;
      C_Stat      : in out AWS.Status.Data) return Response.Data
   is
      use type Status.Protocol_State;

      procedure Create_Session;
      --  Create a session if needed

      function Status_Page (URI : String) return Response.Data;
      --  Handle status page

      function Is_Ignored (Answer : Response.Data) return Boolean;
      --  Returns True if the Answer is to be ignored based on If-Match or
      --  If-Not-Match and ETag if any.

      Admin_URI : constant String := CNF.Admin_URI (HTTP_Server.Properties);

      --------------------
      -- Create_Session --
      --------------------

      procedure Create_Session is
      begin
         if CNF.Session (HTTP_Server.Properties)
           and then (not Status.Has_Session (C_Stat)
                     or else not Session.Exist (Status.Session (C_Stat)))
         then
            --  Generate the session ID
            Status.Set.Session (C_Stat);
         end if;
      end Create_Session;

      ----------------
      -- Is_Ignored --
      ----------------

      function Is_Ignored (Answer : Response.Data) return Boolean is
      begin
         if Response.Has_Header (Answer, Messages.ETag_Token) then
            declare
               ETag : constant String :=
                        Response.Header (Answer, Messages.ETag_Token);
               H    : constant Headers.List := Status.Header (C_Stat);
            begin
               --  The request must be ignored if the header If_Match is
               --  found and the ETag does not correspond or if the header
               --  If-None-Match is found and the ETag correspond.

               return (H.Exist (Messages.If_Match_Token)
                       and then Strings.Fixed.Index
                         (H.Get_Values (Messages.If_Match_Token), ETag) = 0)
                 or else
                   (H.Exist (Messages.If_None_Match_Token)
                    and then Strings.Fixed.Index
                      (H.Get_Values (Messages.If_None_Match_Token),
                       ETag) /= 0);
            end;

         else
            return False;
         end if;
      end Is_Ignored;

      -----------------
      -- Status_Page --
      -----------------

      function Status_Page (URI : String) return Response.Data is
         use type AWS.Status.Authorization_Type;
         Answer   : Response.Data;
         Username : constant String :=
                      AWS.Status.Authorization_Name (C_Stat);
         Password : constant String :=
                      AWS.Status.Authorization_Password (C_Stat);
         Method   : constant AWS.Status.Authorization_Type :=
                      AWS.Status.Authorization_Mode (C_Stat);

         procedure Answer_File (File_Name : String);
         --  Assign File to Answer response data

         -----------------
         -- Answer_File --
         -----------------

         procedure Answer_File (File_Name : String) is
         begin
            Answer := Response.File
              (Content_Type => MIME.Content_Type (File_Name),
               Filename     => File_Name);
         end Answer_File;

      begin
         --  First check for authentification

         if Method = AWS.Status.Digest then
            if AWS.Status.Authorization_Response (C_Stat)
               = GNAT.MD5.Digest
                   (CNF.Admin_Password (HTTP_Server.Properties)
                    & AWS.Status.Authorization_Tail (C_Stat))
            then
               if not AWS.Digest.Check_Nonce
                 (Status.Authorization_Nonce (C_Stat))
               then
                  return AWS.Response.Authenticate
                    (CNF.Admin_Realm (HTTP_Server.Properties),
                     AWS.Response.Digest,
                     Stale => True);
               end if;

            else
               return AWS.Response.Authenticate
                 (CNF.Admin_Realm (HTTP_Server.Properties),
                  AWS.Response.Digest);
            end if;

         elsif (Method = AWS.Status.Basic
                and then CNF.Admin_Password (HTTP_Server.Properties)
                         /= GNAT.MD5.Digest
                              (Username
                               & ':' & CNF.Admin_Realm (HTTP_Server.Properties)
                               & ':' & Password))
           or else Method = AWS.Status.None or else Password = ""
         then
            return Response.Authenticate
              (CNF.Admin_Realm (HTTP_Server.Properties), Response.Any);
         end if;

         if URI = Admin_URI then
            --  Status page

            begin
               Answer := Response.Build
                 (Content_Type => MIME.Text_HTML,
                  Message_Body => Get_Status (HTTP_Server));
            exception
               when Templates.Template_Error =>
                  Answer := Response.Build
                    (Content_Type => MIME.Text_HTML,
                     Message_Body =>
                     "Status template error. Please check "
                     & "that '" & CNF.Status_Page (HTTP_Server.Properties)
                     & "' file is valid.");
            end;

         elsif URI = Admin_URI & "-logo" then
            --  Status page logo
            Answer_File (CNF.Logo_Image (HTTP_Server.Properties));

         elsif URI = Admin_URI & "-uparr" then
            --  Status page hotplug up-arrow
            Answer_File (CNF.Up_Image (HTTP_Server.Properties));

         elsif URI = Admin_URI & "-downarr" then
            --  Status page hotplug down-arrow
            Answer_File (CNF.Down_Image (HTTP_Server.Properties));

         elsif URI = Admin_URI & "-HPup" then
            --  Status page hotplug up message
            Hotplug.Move_Up
              (HTTP_Server.Filters,
               Positive'Value (Status.Parameter (C_Stat, "N")));
            Answer := Response.URL (Admin_URI);

         elsif URI = Admin_URI & "-HPdown" then
            --  Status page hotplug down message
            Hotplug.Move_Down
              (HTTP_Server.Filters,
               Positive'Value (Status.Parameter (C_Stat, "N")));
            Answer := Response.URL (Admin_URI);

         else
            Answer := Response.Build
              (Content_Type => MIME.Text_HTML,
               Message_Body =>
                 "Invalid use of reserved status URI prefix: " & Admin_URI);
         end if;

         return Answer;
      end Status_Page;

      URL : constant AWS.URL.Object := AWS.Status.URI (C_Stat);
      URI : constant String         := AWS.URL.Abs_Path (URL);

      Answer : Response.Data;

   begin
      --  Check if the status page, status page logo or status page images
      --  are requested. These are AWS internal data that should not be
      --  handled by AWS users.

      --  AWS Internal status page handling

      if Admin_URI'Length > 0
        and then
          URI'Length >= Admin_URI'Length
          and then
            URI (URI'First .. URI'First + Admin_URI'Length - 1) = Admin_URI
      then
         Answer := Status_Page (URI);

         --  Check if the URL is trying to reference resource above Web root
         --  directory.

      elsif CNF.Check_URL_Validity (HTTP_Server.Properties)
        and then not AWS.URL.Is_Valid (URL)
      then
         --  403 status code "Forbidden"

         Answer := Response.Build
           (Status_Code   => Messages.S403,
            Content_Type  => "text/plain",
            Message_Body  => "Request " & URI & ASCII.LF
            & " trying to reach resource above the Web root directory.");

         --  Check if we have a websockets request

      elsif Headers.Values.Unnamed_Value_Exists
        (Status.Connection (C_Stat), "upgrade", Case_Sensitive => False)
        and then
          Headers.Values.Unnamed_Value_Exists
            (Status.Upgrade (C_Stat), "websocket", Case_Sensitive => False)
      then
         Answer := Response.WebSocket;

      else
         --  Otherwise, check if a session needs to be created

         Create_Session;

         --  and get answer from client callback

         declare
            use type Dispatchers.Handler_Class_Access;
            Found : Boolean;
         begin
            --  Check the hotplug filters

            Hotplug.Apply (HTTP_Server.Filters, C_Stat, Found, Answer);

            --  If no one applied, run the user callback

            if not Found then
               if HTTP_Server.New_Dispatcher /= null then
                  HTTP_Server.Dispatcher_Sem.Write;
                  Dispatchers.Free (HTTP_Server.Dispatcher);
                  HTTP_Server.Dispatcher := HTTP_Server.New_Dispatcher;
                  HTTP_Server.New_Dispatcher := null;
                  HTTP_Server.Dispatcher_Sem.Release_Write;
               end if;

               Answer := Call_For_Dispatcher (HTTP_Server, C_Stat);
            end if;

            --  Switching protocol if needed and server has HTTP/2
            --  activated.

            if Status.Protocol (C_Stat) = Status.Upgrade_To_H2C
              and then AWS.Config.HTTP2_Activated (HTTP_Server.Config)
            then
               Response.Set.Status_Code (Answer, Messages.S101);
               Response.Set.Add_Header
                 (Answer, Messages.Connection_Token, Messages.Upgrade_Token);
               Response.Set.Add_Header
                 (Answer, Messages.Upgrade_Token, Messages.H2C_Token);
            end if;

            --  Then check if the answer is to be ignored as per
            --  If-Match/If-None-Match and ETag values.

            if Is_Ignored (Answer) then
               Answer := Response.Acknowledge (Messages.S304);
            end if;
         end;

         AWS.Status.Set.Delete_Idle_Session (C_Stat);
      end if;

      return Answer;
   end Build_Answer;

   -------------------------
   -- Call_For_Dispatcher --
   -------------------------

   function Call_For_Dispatcher
     (HTTP_Server : in out AWS.Server.HTTP;
      C_Stat      : AWS.Status.Data) return Response.Data is
   begin
      HTTP_Server.Dispatcher_Sem.Read;

      --  Be sure to always release the read semaphore

      return Answer : constant Response.Data :=
        Dispatchers.Dispatch (HTTP_Server.Dispatcher.all, C_Stat)
      do
         HTTP_Server.Dispatcher_Sem.Release_Read;
      end return;

   exception
      when others =>
         HTTP_Server.Dispatcher_Sem.Release_Read;
         raise;
   end Call_For_Dispatcher;

   ---------------------
   -- File_Upload_UID --
   ---------------------

   protected body File_Upload_UID is

      ---------
      -- Get --
      ---------

      procedure Get (ID : out Natural) is
      begin
         ID  := UID;
         UID := @ + 1;
      end Get;

   end File_Upload_UID;

   -------------------------
   -- Multipart_Message_G --
   -------------------------

   package body Multipart_Message_G is

      procedure Read is new Headers.Read_G (Get_Line);
      --  Read header using generic Get_Line

      -----------------
      -- File_Upload --
      -----------------

      procedure File_Upload
        (C_Stat                       : in out Status.Data;
         Attachments                  : in out AWS.Attachments.List;
         Start_Boundary, End_Boundary : String;
         Parse_Boundary               : Boolean)
      is

         procedure Target_Filename
           (Filename                                 : String;
            Server_Filename, Decoded_Server_Filename : out Unbounded_String);
         --  Returns the full path names (std and decoded) for the
         --  file as stored on the server side.

         ---------------------
         -- Target_Filename --
         ---------------------

         procedure Target_Filename
           (Filename                                 : String;
            Server_Filename, Decoded_Server_Filename : out Unbounded_String)
         is
            Upload_Path     : constant String :=
                                CNF.Upload_Directory (Server_Config);
            File_Upload_UID : constant String := Get_File_Upload_UID;
         begin
            Server_Filename := To_Unbounded_String
              (Upload_Path & File_Upload_UID & '.' & Filename);

            Decoded_Server_Filename := To_Unbounded_String
              (Upload_Path & File_Upload_UID & '.' & URL.Decode (Filename));
         end Target_Filename;

         Name                    : Unbounded_String;
         Filename                : Unbounded_String;
         Server_Filename         : Unbounded_String;
         Decoded_Server_Filename : Unbounded_String;
         Is_File_Upload          : Boolean;
         Headers                 : AWS.Headers.List;

         End_Found               : Boolean := False;
         --  Set to true when the end-boundary has been found

      begin
         --  Reach the boundary

         if Parse_Boundary then
            loop
               declare
                  Data : constant String := Get_Line;
               begin
                  exit when Data = Start_Boundary;

                  if Data = End_Boundary then
                     --  This is the end of the multipart data
                     return;
                  end if;
               end;
            end loop;
         end if;

         --  Read header

         Read (Headers);

         if AWS.Headers.Get_Values
           (Headers, Messages.Content_Type_Token) = MIME.Application_Form_Data
         then
            --  This chunk is the form parameter

            Read_Body (C_Stat, Boundary => Start_Boundary);

            --  Skip CRLF after boundary

            declare
               Data : constant String := Get_Line with Unreferenced;
            begin
               null;
            end;

            File_Upload
              (C_Stat, Attachments, Start_Boundary, End_Boundary, False);

            Status.Set.Parameters_From_Body
              (C_Stat, (if Is_H2 then Start_Boundary else ""));

         else
            --  Read file upload parameters

            declare
               Data       : constant String :=
                              AWS.Headers.Get_Values
                                (Headers, Messages.Content_Disposition_Token);
               L_Name     : constant String :=
                              AWS.Headers.Values.Search (Data, "name");
               L_Filename : constant String :=
                              URL.Decode
                                (AWS.Headers.Values.Search (Data, "filename"));
               --  Get the simple name as we do not want to expose the client
               --  full pathname to the user's callback. Microsoft Internet
               --  Explorer sends the full pathname, Firefox only send the
               --  simple name.
            begin
               Is_File_Upload := (L_Filename /= "");

               Name := To_Unbounded_String (L_Name);

               if Is_File_Upload then
                  Filename := To_Unbounded_String
                    (URL.Encode (Directories.Simple_Name (L_Filename)));
               end if;
            end;

            --  Read file/field data

            if Is_File_Upload then
               --  This part of the multipart message contains file data

               if CNF.Upload_Directory (Server_Config) = "" then
                  raise Constraint_Error
                    with "File upload not supported by server "
                      & CNF.Server_Name (Server_Config);
               end if;

               --  Set Server_Filename, the name of the file in the local file
               --  sytstem.

               Target_Filename
                 (To_String (Filename),
                  Server_Filename, Decoded_Server_Filename);

               if To_String (Filename) /= "" then
                  --  First value is the unique name on the server side

                  Status.Set.Add_Parameter
                    (C_Stat, To_String (Name), To_String (Server_Filename));
                  --  Status.Set.Add_Parameter does not decode values

                  --  Second value is the original name as found on the client
                  --  side.

                  Status.Set.Add_Parameter
                    (C_Stat, To_String (Name), To_String (Filename));
                  --  Status.Set.Add_Parameter does not decode values

                  --  Read file data, set End_Found if the end-boundary
                  --  signature has been read.

                  Get_File_Data
                    (C_Stat,
                     Attachments,
                     To_String (Decoded_Server_Filename),
                     To_String (Filename),
                     Start_Boundary,
                     File_Upload,
                     Headers,
                     End_Found);

                  --  Create an attachment entry, this will ensure that the
                  --  physical file will be removed. It will also be possible
                  --  to work with the attachment instead of the parameters set
                  --  above.

                  AWS.Attachments.Add
                    (Attachments,
                     Filename   => To_String (Decoded_Server_Filename),
                     Name       => To_String (Filename),
                     Content_Id => To_String (Name),
                     Headers    => Headers);
                  Status.Set.Attachments (C_Stat, Attachments);

                  if not End_Found then
                     File_Upload
                       (C_Stat, Attachments,
                        Start_Boundary, End_Boundary, False);
                  end if;

               else
                  --  There is no file for this multipart, user did not enter
                  --  something in the field.

                  File_Upload
                    (C_Stat, Attachments, Start_Boundary, End_Boundary, True);
               end if;

            else
               --  This part of the multipart message contains field values

               declare
                  Value : Unbounded_String;
               begin
                  loop
                     declare
                        L : constant String := Get_Line;
                     begin
                        End_Found := (L = End_Boundary);

                        exit when End_Found or else L = Start_Boundary;

                        --  Append this line to the value

                        Utils.Append_With_Sep
                          (Value, L, Sep => ASCII.CR & ASCII.LF);
                     end;
                  end loop;

                  Status.Set.Add_Parameter
                    (C_Stat, Name, Value, Decode => False);
                  --  Do not decode values for multipart/form-data
               end;

               if not End_Found then
                  File_Upload
                    (C_Stat, Attachments, Start_Boundary, End_Boundary, False);
               end if;
            end if;
         end if;
      end File_Upload;

      -------------------
      -- Get_File_Data --
      -------------------

      procedure Get_File_Data
        (C_Stat          : in out Status.Data;
         Attachments     : in out AWS.Attachments.List;
         Server_Filename : String;
         Filename        : String;
         Start_Boundary  : String;
         Mode            : Message_Mode;
         Headers         : AWS.Headers.List;
         End_Found       : out Boolean)
      is
         type Error_State is (No_Error, Name_Error, Device_Error);
         --  This state is to monitor the file upload process. If we receice
         --  Name_Error or Device_Error while writing data on disk we need to
         --  continue reading all data from the socket if we want to be able
         --  to send back an error message.

         function Check_EOF return Boolean;
         --  Returns True if we have reach the end of file data

         procedure Write
           (Buffer : Streams.Stream_Element_Array; Trim : Boolean) with Inline;
         --  Write buffer to the file, handle the Device_Error exception

         File   : Streams.Stream_IO.File_Type;
         Buffer : Streams.Stream_Element_Array (1 .. 4 * 1_024);
         Index  : Streams.Stream_Element_Offset := Buffer'First;

         Data   : Streams.Stream_Element_Array (1 .. 1);
         Data2  : Streams.Stream_Element_Array (1 .. 2);
         Error  : Error_State := No_Error;

         ---------------
         -- Check_EOF --
         ---------------

         function Check_EOF return Boolean is

            Signature : constant Streams.Stream_Element_Array :=
                          [1 => 13, 2 => 10]
                            & Translator.To_Stream_Element_Array
                                (Start_Boundary);

            Buffer : Streams.Stream_Element_Array (1 .. Signature'Length);
            Index  : Streams.Stream_Element_Offset := Buffer'First;

            procedure Write_Data;
            --  Put buffer data into the main buffer (Get_Data.Buffer). If
            --  the main buffer is not big enough, it will write the buffer
            --  into the file before.

            ----------------
            -- Write_Data --
            ----------------

            procedure Write_Data is
            begin
               if Error /= No_Error then
                  return;
               end if;

               if Get_File_Data.Buffer'Last
                 < Get_File_Data.Index + Index - 1
               then
                  Write (Get_File_Data.Buffer
                           (Get_File_Data.Buffer'First
                              .. Get_File_Data.Index - 1), False);
                  Get_File_Data.Index := Get_File_Data.Buffer'First;
               end if;

               Get_File_Data.Buffer
                 (Get_File_Data.Index .. Get_File_Data.Index + Index - 2) :=
                 Buffer (Buffer'First .. Index - 1);

               Get_File_Data.Index := Get_File_Data.Index + Index - 1;
            end Write_Data;

         begin -- Check_EOF
            Buffer (Index) := 13;
            Index := @ + 1;

            loop
               Read (Data);

               if Data (1) = 13 then
                  Write_Data;
                  return False;
               end if;

               Buffer (Index) := Data (1);

               if Index = Buffer'Last then
                  if Buffer = Signature then
                     return True;
                  else
                     Write_Data;
                     return False;
                  end if;
               end if;

               Index := @ + 1;
            end loop;
         end Check_EOF;

         -----------
         -- Write --
         -----------

         procedure Write
           (Buffer : Streams.Stream_Element_Array; Trim : Boolean) is
         begin
            if Error = No_Error then
               if Mode in Attachment .. File_Upload then
                  Streams.Stream_IO.Write (File, Buffer);
               else
                  --  This is the root part of an MIME attachment, append the
                  --  data to the status record.
                  Status.Set.Append_Body (C_Stat, Buffer, Trim);
               end if;
            end if;
         exception
            when Text_IO.Device_Error =>
               Error := Device_Error;
         end Write;

      begin
         begin
            if Mode in Attachment .. File_Upload then
               Streams.Stream_IO.Create
                 (File, Streams.Stream_IO.Out_File, Server_Filename);
            end if;
         exception
            when Text_IO.Name_Error =>
               Error := Name_Error;
         end;

         Read_File : loop
            Read (Data);

            while Data (1) = 13 loop
               exit Read_File when Check_EOF;
            end loop;

            Buffer (Index) := Data (1);
            Index := Index + 1;

            if Index > Buffer'Last then
               Write (Buffer, False);
               Index := Buffer'First;

               Check_Data_Timeout;
            end if;
         end loop Read_File;

         if Index /= Buffer'First then
            Write (Buffer (Buffer'First .. Index - 1), True);
         end if;

         if Error = No_Error then
            case Mode is
               when Root_Attachment =>
                  null;

               when Attachment =>
                  Streams.Stream_IO.Close (File);
                  AWS.Attachments.Add
                    (Attachments, Server_Filename, Headers, Filename);

               when File_Upload =>
                  Streams.Stream_IO.Close (File);
            end case;
         end if;

         --  Check for end-boundary, at this point we have at least two
         --  chars. Either the terminating "--" or CR+LF.

         Read (Data2);

         if Data2 (2) = 10 then
            --  We have CR+LF, it is a start-boundary
            End_Found := False;

         else
            --  We have read the "--", read line terminator. This is the
            --  end-boundary.

            End_Found := True;
            Read (Data2);
         end if;

         if Error = Name_Error then
            --  We can't create the file, add a clear exception message
            raise HTTP_Utils.Name_Error
              with "Cannot create file " & Server_Filename;

         elsif Error = Device_Error then
            --  We can't write to the file, there is probably no space left
            --  on devide.
            raise HTTP_Utils.Device_Error
              with "No space left on device while writing " & Server_Filename;
         end if;
      end Get_File_Data;

      -------------------------
      -- Get_File_Upload_UID --
      -------------------------

      function Get_File_Upload_UID return String is
         use GNAT;
         Pid : constant Natural := Integer'Max
                 (0, OS_Lib.Pid_To_Integer (OS_Lib.Current_Process_Id));
         --  On OS where Current_Process_Id is not support -1 is returned. We
         --  ensure that in this case the Pid is set to 0 in this case.
         UID : Natural;
      begin
         File_Upload_UID.Get (UID);

         return Utils.Image (Pid) & "-" & Utils.Image (UID);
      end Get_File_Upload_UID;

      -----------------------
      -- Store_Attachments --
      -----------------------

      procedure Store_Attachments
        (C_Stat                       : in out Status.Data;
         Attachments                  : in out AWS.Attachments.List;
         Start_Boundary, End_Boundary : String;
         Parse_Boundary               : Boolean;
         Multipart_Boundary           : String;
         Root_Part_CID                : String)
      is
         function Attachment_Filename (Extension : String) return String;
         --  Returns the full path name for the file as stored on the
         --  server side.

         -------------------------
         -- Attachment_Filename --
         -------------------------

         function Attachment_Filename (Extension : String) return String is
            Upload_Path : constant String :=
                            CNF.Upload_Directory (Server_Config);
         begin
            if Extension = "" then
               return Upload_Path & Get_File_Upload_UID;
            else
               return Upload_Path & Get_File_Upload_UID & '.' & Extension;
            end if;
         end Attachment_Filename;

         Server_Filename : Unbounded_String;
         Content_Id      : Unbounded_String;
         Headers         : AWS.Headers.List;

         End_Found       : Boolean := False;
         --  Set to true when the end-boundary has been found

      begin
         --  Reach the boundary

         if Parse_Boundary then
            loop
               declare
                  Data : constant String := Get_Line;
               begin
                  exit when Data = Start_Boundary;

                  if Data = End_Boundary then
                     --  This is the end of the multipart data
                     return;
                  end if;
               end;
            end loop;
         end if;

         --  Read header

         Read (Headers);

         if AWS.Headers.Get_Values
           (Headers, Messages.Content_Type_Token) = MIME.Application_Form_Data
         then
            --  This chunk is the form parameter
            Read_Body (C_Stat, Boundary => "--" & Multipart_Boundary);

            --  Skip CRLF after boundary

            declare
               Data : constant String := Get_Line with Unreferenced;
            begin
               null;
            end;

            Store_Attachments
              (C_Stat, Attachments,
               Start_Boundary, End_Boundary, False,
               Multipart_Boundary, Root_Part_CID);

            --  In HTTP/2 the whole message is read with the multipart header
            --  for the main form data.

            Status.Set.Parameters_From_Body
              (C_Stat, (if Is_H2 then Start_Boundary else ""));

         else
            Content_Id := To_Unbounded_String
              (AWS.Headers.Get (Headers, Messages.Content_Id_Token));

            --  Read file/field data

            if Content_Id = Root_Part_CID then
               Get_File_Data
                 (C_Stat, Attachments,
                  "", "", Start_Boundary, Root_Attachment, Headers, End_Found);

            else
               Server_Filename := To_Unbounded_String
                 (Attachment_Filename
                    (AWS.MIME.Extension
                       (AWS.Headers.Values.Get_Unnamed_Value
                          (AWS.Headers.Get
                             (Headers, Messages.Content_Type_Token)))));

               Get_File_Data
                 (C_Stat, Attachments,
                  To_String (Server_Filename), To_String (Server_Filename),
                  Start_Boundary, Attachment, Headers, End_Found);
            end if;

            --  More attachments ?

            if End_Found then
               AWS.Status.Set.Attachments (C_Stat, Attachments);
            else
               Store_Attachments
                 (C_Stat, Attachments,
                  Start_Boundary, End_Boundary, False,
                  Multipart_Boundary, Root_Part_CID);
            end if;
         end if;
      end Store_Attachments;

   end Multipart_Message_G;

   ----------------------
   -- Get_Message_Data --
   ----------------------

   procedure Get_Message_Data
     (HTTP_Server : AWS.Server.HTTP;
      Line_Index  : Positive;
      C_Stat      : in out AWS.Status.Data;
      Expect_100  : Boolean)
   is
      use type Status.Request_Method;

      Status_Multipart_Boundary : Unbounded_String;
      Status_Root_Part_CID      : Unbounded_String;
      Status_Content_Type       : Unbounded_String;

      Sock : constant Net.Socket_Type'Class := Status.Socket (C_Stat);

      Attachments : AWS.Attachments.List;

      function Get_Line return String;
      --  Read a line from Sock

      procedure Read (Buffer : out Stream_Element_Array);
      --  Fill buffer from Sock

      procedure Read_Body (Stat : in out Status.Data; Boundary : String);
      --  Read Sock until Boundary is found

      procedure Check_Data_Timeout;
      --  Check data time-out using server settings

      ------------------------
      -- Check_Data_Timeout --
      ------------------------

      procedure Check_Data_Timeout is
      begin
         HTTP_Server.Slots.Check_Data_Timeout (Line_Index);
      end Check_Data_Timeout;

      --------------
      -- Get_Line --
      --------------

      function Get_Line return String is
      begin
         return Net.Buffered.Get_Line (Sock);
      end Get_Line;

      ----------
      -- Read --
      ----------

      procedure Read (Buffer : out Stream_Element_Array) is
      begin
         Net.Buffered.Read (Sock, Buffer);
      end Read;

      ---------------
      -- Read_Body --
      ---------------

      procedure Read_Body (Stat : in out Status.Data; Boundary : String) is
      begin
         Status.Set.Read_Body (Sock, Stat, Boundary => Boundary);
      end Read_Body;

      -----------------------
      -- Multipart_Message --
      -----------------------

      package Multipart_Message is new Multipart_Message_G
        (False, HTTP_Server.Properties,
         Get_Line, Read, Read_Body, Check_Data_Timeout);

   begin
      if Expect_100 then
         Net.Buffered.Put_Line (Sock, Messages.Status_Line (Messages.S100));
         Net.Buffered.New_Line (Sock);
         Net.Buffered.Flush (Sock);
      end if;

      --  Get necessary data from header for reading HTTP body

      declare

         procedure Named_Value
           (Name, Value : String; Quit : in out Boolean);
         --  Looking for the Boundary value in the  Content-Type header line

         procedure Value (Item : String; Quit : in out Boolean);
         --  Reading the first unnamed value into the Status_Content_Type
         --  variable from the Content-Type header line.

         -----------------
         -- Named_Value --
         -----------------

         procedure Named_Value
           (Name, Value : String; Quit : in out Boolean)
         is
            pragma Unreferenced (Quit);
            L_Name : constant String :=
                        Ada.Characters.Handling.To_Lower (Name);
         begin
            if L_Name = "boundary" then
               Status_Multipart_Boundary := To_Unbounded_String (Value);
            elsif L_Name = "start" then
               Status_Root_Part_CID := To_Unbounded_String (Value);
            end if;
         end Named_Value;

         -----------
         -- Value --
         -----------

         procedure Value (Item : String; Quit : in out Boolean) is
         begin
            if Status_Content_Type /= Null_Unbounded_String then
               --  Only first unnamed value is the Content_Type

               Quit := True;

            elsif Item'Length > 0 then
               Status_Content_Type := To_Unbounded_String (Item);
            end if;
         end Value;

         procedure Parse is new Headers.Values.Parse (Value, Named_Value);

      begin
         --  Clear Content-Type status as this could have already been set
         --  in previous request.

         Status_Content_Type := Null_Unbounded_String;

         Parse (Status.Content_Type (C_Stat));
      end;

      if Status.Method (C_Stat) = Status.POST
        and then Status_Content_Type = MIME.Application_Form_Data
      then
         --  Read data from the stream and convert it to a string as
         --  these are a POST form parameters.
         --  The body has the format: name1=value1&name2=value2...

         Status.Set.Read_Body (Sock, C_Stat);

         Status.Set.Parameters_From_Body (C_Stat);

      elsif Status.Method (C_Stat) = Status.POST
        and then Status_Content_Type = MIME.Multipart_Form_Data
      then
         --  This is a file upload

         Multipart_Message.File_Upload
           (C_Stat,
            Attachments,
            "--" & To_String (Status_Multipart_Boundary),
            "--" & To_String (Status_Multipart_Boundary) & "--",
            True);

      elsif Status.Method (C_Stat) = Status.POST
        and then Status_Content_Type = MIME.Multipart_Related
      then
         --  Attachments are to be written to separate files

         Multipart_Message.Store_Attachments
           (C_Stat,
            Attachments,
            "--" & To_String (Status_Multipart_Boundary),
            "--" & To_String (Status_Multipart_Boundary) & "--",
            True,
            To_String (Status_Multipart_Boundary),
            To_String (Status_Root_Part_CID));

      else
         --  Let's suppose for now that all others content type data are
         --  binary data.

         Status.Set.Read_Body (Sock, C_Stat);
      end if;

      Status.Reset_Body_Index (C_Stat);

      HTTP_Server.Slots.Mark_Phase (Line_Index, Server_Processing);
      Status.Set.Uploaded (C_Stat);
   end Get_Message_Data;

   ----------------------
   -- Get_Request_Line --
   ----------------------

   procedure Get_Request_Line (C_Stat : in out AWS.Status.Data) is
      use type Status.Protocol_State;
      Sock : constant Net.Socket_Type'Class := Status.Socket (C_Stat);
   begin
      --  Get and parse request line

      loop
         declare
            Data : constant String := Net.Buffered.Get_Line (Sock);

            function Is_Next (Item : String) return Boolean is
              (Net.Buffered.Get_Line (Sock) = Item);

         begin
            --  RFC 2616
            --  4.1 Message Types
            --  ....................
            --  In the interest of robustness, servers SHOULD ignore any empty
            --  line(s) received where a Request-Line is expected.

            if Data /= "" then
               if not Sock.Is_Secure
                 and then Status.Protocol (C_Stat) = Status.HTTP_1
                 and then Data = HTTP2.Client_Connection_Preface_1
                 and then Is_Next ("")
                 and then Is_Next (HTTP2.Client_Connection_Preface_2)
                 and then Is_Next ("")
               then
                  --  Plain socket client starts with HTTP/2 connection
                  --  preface, i.e. client assume that server has HTTP/2
                  --  support (RFC 7540, 3.4.). Set the Protocol to H2 and
                  --  check for HTTP/2 server support in Protocol_Handler where
                  --  this routine is called from.

                  Status.Set.Protocol (C_Stat, Status.H2);
                  exit;
               end if;

               Parse_Request_Line (Data, C_Stat);
               exit;
            end if;
         end;
      end loop;
   end Get_Request_Line;

   -------------------------
   -- Get_Resource_Status --
   -------------------------

   function Get_Resource_Status
     (C_Stat    : Status.Data;
      Filename  : String;
      File_Time : out Ada.Calendar.Time) return Resource_Status
   is
      F_Status : Resource_Status := Changed;
   begin
      File_Time := Utils.AWS_Epoch;

      if Filename /= "" then
         if Resources.Is_Regular_File (Filename) then
            File_Time := Resources.File_Timestamp (Filename);

            if Utils.Is_Valid_HTTP_Date (Status.If_Modified_Since (C_Stat))
              and then
                Messages.To_HTTP_Date (File_Time)
              = Status.If_Modified_Since (C_Stat)
              --  Equal used here see [RFC 2616 - 14.25]
            then
               F_Status := Up_To_Date;
            else
               F_Status := Changed;
            end if;

         else
            F_Status := Not_Found;
         end if;
      end if;

      return F_Status;
   end Get_Resource_Status;

   ----------------
   -- Log_Commit --
   ----------------

   procedure Log_Commit
     (HTTP_Server : in out AWS.Server.HTTP;
      Answer      : Response.Data;
      C_Stat      : AWS.Status.Data;
      Length      : Response.Content_Length_Type)
   is
      LA          : constant Line_Attribute.Attribute_Handle :=
                      Line_Attribute.Reference;
      Status_Code : constant Messages.Status_Code :=
                      Response.Status_Code (Answer);
   begin
      if LA.Skip_Log then
         LA.Skip_Log := False;

      elsif CNF.Log_Extended_Fields_Length (HTTP_Server.Properties) > 0 then
         declare
            use Real_Time;
            use type Strings.Maps.Character_Set;
            Start : constant Time := Status.Request_Time (C_Stat);
         begin
            if Start /= Time_First then
               Log.Set_Field
                 (LA.Server.Log, LA.Log_Data, "time-taken",
                  Utils.Significant_Image (To_Duration (Clock - Start), 3));
            end if;

            Log.Set_Header_Fields
              (LA.Server.Log, LA.Log_Data, "cs", Status.Header (C_Stat));
            Log.Set_Header_Fields
              (LA.Server.Log, LA.Log_Data, "sc", Response.Header (Answer));

            Log.Set_Field
              (LA.Server.Log, LA.Log_Data, "cs-method",
               Status.Method (C_Stat));
            Log.Set_Field
              (LA.Server.Log, LA.Log_Data, "cs-username",
               Status.Authorization_Name (C_Stat));
            Log.Set_Field
              (LA.Server.Log, LA.Log_Data, "cs-version",
               Status.HTTP_Version (C_Stat));

            declare
               use AWS.URL;

               Encoding : constant Strings.Maps.Character_Set :=
                            Strings.Maps.To_Set
                              (Span => (Low  => Character'Val (128),
                                        High => Character'Last))
                            or Strings.Maps.To_Set ("+"" ");

               URI      : constant String :=
                            Encode (Status.URI (C_Stat), Encoding);

               Query    : constant String :=
                            Parameters.URI_Format
                              (Status.Parameters (C_Stat));
            begin
               Log.Set_Field (LA.Server.Log, LA.Log_Data, "cs-uri-stem", URI);
               Log.Set_Field
                 (LA.Server.Log, LA.Log_Data, "cs-uri-query", Query);
               Log.Set_Field
                 (LA.Server.Log, LA.Log_Data, "cs-uri", URI & Query);
            end;

            Log.Set_Field
              (LA.Server.Log, LA.Log_Data, "sc-status",
               Messages.Image (Status_Code));
            Log.Set_Field
              (LA.Server.Log, LA.Log_Data, "sc-bytes", Utils.Image (Length));

            Log.Write (LA.Server.Log, LA.Log_Data);
         end;

      else
         Log.Write (HTTP_Server.Log, C_Stat, Status_Code, Length);
      end if;
   end Log_Commit;

   -------------------------
   -- Parse_Content_Range --
   -------------------------

   procedure Parse_Content_Range
     (H_Value : String;
      Length  : Stream_Element_Offset;
      First   : out Stream_Element_Offset;
      Last    : out Stream_Element_Offset)
   is
      I_Minus : constant Positive := Fixed.Index (H_Value, "-");
   begin
      --  Computer First / Last and the range length

      if I_Minus = H_Value'Last then
         Last := Length - 1;

      else
         Last := Stream_Element_Offset'Value
                   (H_Value (I_Minus + 1 .. H_Value'Last));

         if Last >= Length then
            Last := Length - 1;
         end if;
      end if;

      if H_Value'First = I_Minus then
         --  In this case we want to get the last N bytes from the file
         First := Length - Last;
         Last := Length - 1;

      else
         First := Stream_Element_Offset'Value
                    (H_Value (H_Value'First .. I_Minus - 1));
      end if;
   end Parse_Content_Range;

   ------------------------
   -- Parse_Request_Line --
   ------------------------

   procedure Parse_Request_Line
     (Command : String; C_Stat : in out AWS.Status.Data)
   is

      I1, I2 : Natural;
      --  Index of first space and second space

      Path_Last   : Positive;
      --  Last index of Path part

      Query_First : Positive;
      --  First index of Query part

      procedure Raise_Wrong_Line;
      --  Raise Wrong_Request_Line exception with text message

      ----------------------
      -- Raise_Wrong_Line --
      ----------------------

      procedure Raise_Wrong_Line is
      begin
         raise Wrong_Request_Line with "Wrong request line '" & Command & ''';
      end Raise_Wrong_Line;

   begin
      I1 := Fixed.Index (Command, " ");

      if I1 = 0 then
         Raise_Wrong_Line;
      end if;

      I2 := Fixed.Index (Command (I1 + 1 .. Command'Last), " ", Backward);

      if I2 = 0 or else I1 = I2 then
         Raise_Wrong_Line;
      end if;

      if I2 + 5 >= Command'Last
        or else Command (I2 + 1 .. I2 + 5) /= "HTTP/"
      then
         Raise_Wrong_Line;
      end if;

      Split_Path (Command (I1 + 1 .. I2 - 1), Path_Last, Query_First);

      --  GET and HEAD can have a set of parameters (query) attached. This is
      --  not really standard see [RFC 2616 - 13.9] but is widely used now.
      --
      --  POST parameters are passed into the message body, but we allow
      --  parameters also in this case. It is not clear if it is permitted or
      --  prohibited by reading RFC 2616. Other technologies do offer this
      --  feature so AWS do this as well.

      Status.Set.Request
        (C_Stat,
         Method       => Command (Command'First .. I1 - 1),
         URI          => Command (I1 + 1 .. Path_Last),
         HTTP_Version => Command (I2 + 1 .. Command'Last));

      Status.Set.Query
        (C_Stat,
         Parameters => Command (Query_First .. I2 - 1));
   end Parse_Request_Line;

   ----------
   -- Send --
   ----------

   procedure Send
     (Answer       : in out Response.Data;
      HTTP_Server  : in out AWS.Server.HTTP;
      Line_Index   : Positive;
      C_Stat       : AWS.Status.Data;
      Socket_Taken : in out Boolean;
      Will_Close   : in out Boolean)
   is
      Status_Code : Messages.Status_Code := Response.Status_Code (Answer);
      Length      : Resources.Content_Length_Type := 0;
      H_List      : Headers.List;

      procedure Set_General_Header (Status_Code : Messages.Status_Code);
      --  Send the "Date:", "Server:", "Set-Cookie:" and "Connection:" header

      procedure Send_Header_Only;
      --  Send HTTP message header only. This is used to implement the HEAD
      --  request.

      procedure Send_Data;
      --  Send a text/binary data to the client

      procedure Send_WebSocket_Handshake;
      --  Send reply, accept the switching protocol

      procedure Send_WebSocket_Handshake_Error
        (Status_Code   : Messages.Status_Code;
         Reason_Phrase : String := "");
      --  Deny the WebSocket handshake

      ---------------
      -- Send_Data --
      ---------------

      procedure Send_Data is
         use type AWS.Status.Request_Method;

         Sock      : constant Net.Socket_Type'Class :=
                       Status.Socket (C_Stat);
         Method    : constant AWS.Status.Request_Method :=
                       Status.Method (C_Stat);
         Filename  : constant String :=
                       Response.Filename (Answer);
         File_Mode : constant Boolean :=
                       Response.Mode (Answer) in
                         Response.File .. Response.Stream;
         With_Body : constant Boolean := Messages.With_Body (Status_Code);
         File_Time : Ada.Calendar.Time;
         F_Status  : constant Resource_Status :=
                       (if File_Mode
                        then Get_Resource_Status (C_Stat, Filename, File_Time)
                        else Changed);
         File      : Resources.File_Type;
      begin
         if File_Mode and then F_Status in Up_To_Date .. Not_Found then
            if F_Status = Up_To_Date then
               --  [RFC 2616 - 10.3.5]
               Status_Code := Messages.S304;
            else
               --  File is not found on disk, returns now with 404
               Status_Code := Messages.S404;
            end if;

            Send_Header_Only;

            return;

         elsif Headers.Get_Values
                 (Status.Header (C_Stat), Messages.Range_Token) /= ""
           and then With_Body
         then
            --  Partial range request, answer accordingly
            Status_Code := Messages.S206;
         end if;

         --  Note. We have to call Create_Resource before send header fields
         --  defined in the Answer to the client, because this call could
         --  setup Content-Encoding header field to Answer. Answer header
         --  lines would be send below in the Send_General_Header.

         Response.Create_Resource
           (Answer, File, AWS.Status.Is_Supported (C_Stat, Messages.GZip));

         --  Length is the real resource/file size

         Length := Resources.Size (File);

         --  Checking if we have to close connection because of undefined
         --  message length coming from a user's stream. Or because of user
         --  do not want to keep connection alive.

         if (Length = Resources.Undefined_Length
             and then Status.HTTP_Version (C_Stat) = HTTP_10
             --  We cannot use transfer-encoding chunked in HTTP_10
             and then Method /= Status.HEAD)
             --  We have to send message_body
           or else not Response.Keep_Alive (Answer)
         then
            --  In this case we need to close the connection explicitly at the
            --  end of the transfer.
            Will_Close := True;
         end if;

         Set_General_Header (Status_Code);

         --  Send file last-modified timestamp info in case of a file

         if File_Mode
           and then
             not Response.Has_Header (Answer, Messages.Last_Modified_Token)
         then
            Headers.Add
              (Table => H_List,
               Name  => Messages.Last_Modified_Token,
               Value => Messages.To_HTTP_Date (File_Time));
         end if;

         --  Send Cache-Control, Location, WWW-Authenticate and others
         --  user defined header lines.

         Headers.Send_Header
           (Socket    => Sock,
            Headers   => H_List,
            End_Block => False);

         Response.Send_Header (Socket => Sock, D => Answer);

         --  Note that we cannot send the Content_Length header at this
         --  point. A server should not send Content_Length if the
         --  transfer-coding used is not identity. This is allowed by the
         --  RFC but it seems that some implementation does not handle this
         --  right. The file can be sent using either identity or chunked
         --  transfer-coding. The proper header will be sent in Send_Resource
         --  see [RFC 2616 - 4.4].

         --  Send message body

         if With_Body then
            Send_Resource
              (Answer, File, Length, HTTP_Server.Self, Line_Index, C_Stat);
         else
            --  RFC-2616 4.4
            --  ...
            --  Any response message which "MUST NOT" include a message-body
            --  (such as the 1xx, 204, and 304 responses and any response to a
            --  HEAD request) is always terminated by the first empty line
            --  after the header fields, regardless of the entity-header fields
            --  present in the message.

            Net.Buffered.New_Line (Sock);

            if Length > 0 then
               Log.Write
                 (HTTP_Server.Error_Log, C_Stat,
                  "Message body was not sent. Response with status '"
                  & Messages.Image (Status_Code) & "' can't have it.");
            end if;
         end if;

         Net.Buffered.Flush (Sock);
      end Send_Data;

      ----------------------
      -- Send_Header_Only --
      ----------------------

      procedure Send_Header_Only is
      begin
         --  First let's output the status line

         Set_General_Header (Status_Code);

         Headers.Add
           (Table => H_List,
            Name  => Messages.Content_Type_Token,
            Value => Response.Content_Type (Answer));

         --  There is no content

         Headers.Add
           (Table => H_List,
            Name  => Messages.Content_Length_Token,
            Value => Utils.Image (Stream_Element_Offset'(0)));

         --  Send Cache-Control, Location, WWW-Authenticate and others
         --  user defined header lines.

         Headers.Send_Header
           (Socket    => Status.Socket (C_Stat),
            Headers   => H_List,
            End_Block => False);

         Response.Send_Header
           (Socket    => Status.Socket (C_Stat),
            D         => Answer,
            End_Block => True);
      end Send_Header_Only;

      ------------------------------
      -- Send_WebSocket_Handshake --
      ------------------------------

      procedure Send_WebSocket_Handshake is
         Sock    : constant Net.Socket_Type'Class := Status.Socket (C_Stat);
         Headers : constant AWS.Headers.List := Status.Header (C_Stat);
      begin
         --  First let's output the status line

         Net.Buffered.Put_Line (Sock, Messages.Status_Line (Status_Code));

         --  Send Cache-Control, Location, WWW-Authenticate and others
         --  user defined header lines.

         Response.Send_Header (Socket => Sock, D => Answer);

         if Headers.Exist (Messages.Sec_WebSocket_Key1_Token)
           and then Headers.Exist (Messages.Sec_WebSocket_Key2_Token)
         then
            Net.WebSocket.Protocol.Draft76.Send_Header (Sock, C_Stat);

         else
            --  Send WebSocket-Accept handshake

            Net.WebSocket.Protocol.RFC6455.Send_Header (Sock, C_Stat);

            --  End of header

            Net.Buffered.New_Line (Sock);
            Net.Buffered.Flush (Sock);
         end if;
      end Send_WebSocket_Handshake;

      ------------------------------------
      -- Send_WebSocket_Handshake_Error --
      ------------------------------------

      procedure Send_WebSocket_Handshake_Error
        (Status_Code   : Messages.Status_Code;
         Reason_Phrase : String := "")
      is
         Sock : constant Net.Socket_Type'Class := Status.Socket (C_Stat);
      begin
         --  First let's output the status line

         Net.Buffered.Put_Line
           (Sock, Messages.Status_Line (Status_Code, Reason_Phrase));
         Net.Buffered.Put_Line (Sock, Messages.Content_Length (0));

         --  End of header

         Net.Buffered.New_Line (Sock);
         Net.Buffered.Flush (Sock);
      end Send_WebSocket_Handshake_Error;

      ------------------------
      -- Set_General_Header --
      ------------------------

      procedure Set_General_Header (Status_Code : Messages.Status_Code) is
      begin
         --  The status line

         Headers.Add
           (Table => H_List,
            Name  => HTTP_Version,
            Value => Messages.Status_Value (Status_Code));

         --  Date

         Headers.Add
           (Table => H_List,
            Name  => Messages.Date_Token,
            Value => Messages.To_HTTP_Date (Utils.GMT_Clock));

         --  Server

         declare
            Server : constant String :=
                       CNF.Server_Header (HTTP_Server.Properties);
         begin
            if Server /= "" then
               Headers.Add
                 (Table => H_List,
                  Name  => Messages.Server_Token,
                  Value => Server);
            end if;
         end;

         --  Session

         if CNF.Session (HTTP_Server.Properties)
           and then AWS.Status.Session_Created (C_Stat)
         then
            --  This is an HTTP connection with session but there is no session
            --  ID set yet. So, send cookie to client browser.

            Headers.Add
              (Table => H_List,
               Name  => Messages.Set_Cookie_Token,
               Value => CNF.Session_Name (HTTP_Server.Properties) & '='
                        & Session.Image (AWS.Status.Session (C_Stat))
                        & "; path=/; Version=1");

            --  And the internal private session

            Headers.Add
              (Table => H_List,
               Name  => Messages.Set_Cookie_Token,
               Value => CNF.Session_Private_Name (HTTP_Server.Properties) & '='
                        & AWS.Status.Session_Private (C_Stat)
                        & "; path=/; Version=1");
         end if;

         if Will_Close then
            --  We have decided to close connection after answering the client
            Headers.Add
              (H_List, Messages.Connection_Token, Value => "close");

         else
            Headers.Add
              (H_List, Messages.Connection_Token, Value => "keep-alive");
         end if;
      end Set_General_Header;

   begin
      case Response.Mode (Answer) is
         when Response.File | Response.File_Once | Response.Stream
            | Response.Message
            =>
            HTTP_Server.Slots.Mark_Phase (Line_Index, Server_Response);
            Send_Data;

         when Response.Header =>
            HTTP_Server.Slots.Mark_Phase (Line_Index, Server_Response);
            Send_Header_Only;

         when Response.Socket_Taken =>
            HTTP_Server.Slots.Socket_Taken (Line_Index);
            Socket_Taken := True;

         when Response.WebSocket =>
            Socket_Taken := False;
            Will_Close := True;

            if not CNF.Is_WebSocket_Origin_Set
              or else GNAT.Regexp.Match
                (Status.Origin (C_Stat), CNF.WebSocket_Origin)
            then
               --  Get the WebSocket

               begin
                  declare
                     --  The call to the constructor will raise an exception
                     --  if the WebSocket is not to be accepted. In this case
                     --  a forbidden message is sent back.

                     WS : constant Net.WebSocket.Object'Class :=
                            Net.WebSocket.Registry.Constructor
                              (Status.URI (C_Stat))
                              (Socket  => Status.Socket (C_Stat),
                               Request => C_Stat);
                  begin
                     --  Register this new WebSocket

                     if WS in Net.WebSocket.Handshake_Error.Object'Class then
                        declare
                           E : constant Net.WebSocket.Handshake_Error.Object :=
                                 Net.WebSocket.Handshake_Error.Object (WS);
                        begin
                           Send_WebSocket_Handshake_Error
                             (E.Status_Code, E.Reason_Phrase);
                        end;

                     else
                        --  First try to register the WebSocket object

                        declare
                           use type Net.WebSocket.Object_Class;
                           W : Net.WebSocket.Object_Class;
                        begin
                           W := Net.WebSocket.Registry.Utils.Register (WS);

                           if W = Net.WebSocket.No_Object then
                              Send_WebSocket_Handshake_Error
                                (Messages.S412,
                                 "too many WebSocket registered");

                           else
                              Send_WebSocket_Handshake;

                              HTTP_Server.Slots.Socket_Taken (Line_Index);
                              Socket_Taken := True;
                              Will_Close := False;

                              Net.WebSocket.Registry.Utils.Watch (W);
                           end if;
                        end;
                     end if;

                  exception
                     when E : others =>
                        Send_WebSocket_Handshake_Error
                          (Messages.S403,
                           Exception_Message (E));
                        WS.Shutdown;
                  end;

               exception
                  when E : others =>
                     Send_WebSocket_Handshake_Error
                       (Messages.S403,
                        Exception_Message (E));
                     raise;
               end;

            else
               Send_WebSocket_Handshake_Error (Messages.S403);
            end if;

         when Response.No_Data =>
            raise Constraint_Error
              with "Answer not properly initialized (No_Data)";
      end case;

      --  Status code can be modified, set it back for the logging

      Response.Set.Status_Code (Answer, Status_Code);

      Log_Commit (HTTP_Server, Answer, C_Stat, Length);
   end Send;

   -----------------
   -- Send_File_G --
   -----------------

   procedure Send_File_G
     (HTTP_Server : access AWS.Server.HTTP;
      Line_Index  : Positive;
      File        : in out Resources.File_Type;
      Start       : Stream_Element_Offset;
      Chunk_Size  : Stream_Element_Count;
      Length      : in out Resources.Content_Length_Type)
   is
      Next_Size : Stream_Element_Count := Chunk_Size;
   begin
      Resources.Set_Index (File, Start);

      loop
         declare
            --  Size of the buffer used to send the file
            Last   : Streams.Stream_Element_Offset;
            Buffer : Streams.Stream_Element_Array (1 .. Next_Size);
         begin
            Resources.Read (File, Buffer, Last);

            if Resources.End_Of_File (File) then
               Next_Size := 0;
            end if;

            if Last >= Buffer'First then
               Data (Buffer (1 .. Last), Next_Size);

               Length := @ + Last;
            end if;

            exit when Next_Size = 0;

            --  HTTP_Server is only set when used in server context. When used
            --  in client context it is not defined and we do not check for
            --  timeout.

            if HTTP_Server /= null then
               HTTP_Server.Slots.Check_Data_Timeout (Line_Index);
            end if;
         end;
      end loop;
   end Send_File_G;

   ------------------------
   -- Send_File_Ranges_G --
   ------------------------

   procedure Send_File_Ranges_G
     (HTTP_Server : access AWS.Server.HTTP;
      Line_Index  : Positive;
      File        : in out Resources.File_Type;
      Ranges      : String;
      Chunk_Size  : Stream_Element_Count;
      Length      : in out Resources.Content_Length_Type;
      Answer      : in out Response.Data)
   is
      Boundary    : constant String := "aws_range_separator";
      N_Range     : constant Positive := 1 + Fixed.Count (Ranges, ",");
      N_Minus     : constant Natural  := Fixed.Count (Ranges, "-");
      --  Number of ranges defined
      Equal       : constant Natural := Fixed.Index (Ranges, "=");
      First, Last : Positive;
      Next_Size   : Stream_Element_Offset := Chunk_Size;

      procedure Send_Range (R : String);
      --  Send a single range as defined by R

      procedure Send (Str : String; Last_One : Boolean := False) with Inline;

      ----------
      -- Send --
      ----------

      procedure Send (Str : String; Last_One : Boolean := False) is
         Buffer : constant Stream_Element_Array :=
                    Translator.To_Stream_Element_Array (Str);
         First : Stream_Element_Offset := Buffer'First;
         Last  : Stream_Element_Offset;
      begin
         loop
            Last := Stream_Element_Offset'Min
              (First + Next_Size - 1, Buffer'Last);

            if Last_One and then Last = Buffer'Last then
               Next_Size := 0;
            end if;

            Data (Buffer (First .. Last), Next_Size);
            exit when Last = Buffer'Last;
            First := Last + 1;
         end loop;
      end Send;

      ----------------
      -- Send_Range --
      ----------------

      procedure Send_Range (R : String) is
         R_First  : Stream_Element_Offset;
         R_Last   : Stream_Element_Offset;
         R_Length : Stream_Element_Offset;
      begin
         if N_Range /= 1 then
            --  Send the multipart/byteranges
            Send ("--" & Boundary & CRLF);
         end if;

         Parse_Content_Range (R, Length, R_First, R_Last);

         R_Length := R_Last - R_First + 1;

         if N_Range /= 1 or else not Is_H2 then
            --  Only issue the Content-Range & Content-Length header in HTTP/1
            --  or if there is multiple ranges as this will be part of the
            --  body.
            --
            --  Content-Range: bytes <first>-<last>/<length>

            Send
              (Messages.Content_Range_Token & ": bytes "
               & Utils.Image (R_First) & "-"
               & Utils.Image (R_Last)
               & "/" & Utils.Image (Length)
               & CRLF
               & Messages.Content_Length (R_Length) & CRLF & CRLF);
         end if;

         Resources.Set_Index (File, R_First + 1);

         declare
            Buffer : Streams.Stream_Element_Array (1 .. Chunk_Size);
            Sent   : Stream_Element_Offset := 0;
            Size   : Stream_Element_Offset := 0;
            Last   : Stream_Element_Offset;
         begin
            loop
               Size := R_Length - Sent;

               exit when Size = 0;

               if Size > Next_Size then
                  Size := Next_Size;
               elsif N_Range = 1 then
                  Next_Size := 0;
               end if;

               Resources.Read (File, Buffer (1 .. Size), Last);

               exit when Last < Buffer'First;

               Data (Buffer (1 .. Last), Next_Size);

               Sent := @ + Last;

               HTTP_Server.Slots.Check_Data_Timeout (Line_Index);
            end loop;
         end;
      end Send_Range;

   begin
      --  In HTTP/2 mode the headers have already been taken care of

      if not Is_H2 then
         --  Check range definition

         if N_Range /= N_Minus
           or else Equal = 0
           or else Ranges (Ranges'First .. Equal - 1) /= "bytes"
         then
            --  Range is wrong, let's send the whole file then
            Send_File (HTTP_Server, Line_Index, File, 1, Chunk_Size, Length);
            return;
         end if;

         if N_Range = 1 then
            Send
              (Messages.Content_Type (Response.Content_Type (Answer)) & CRLF);

         else
            --  Then we will send a multipart/byteranges

            Send
              (Messages.Content_Type
                 (MIME.Multipart_Byteranges & "; boundary=" & Boundary)
               & CRLF);
         end if;
      end if;

      First := Equal + 1;

      for K in 1 .. N_Range loop
         if K = N_Range then
            Last := Ranges'Last;
         else
            Last := Fixed.Index (Ranges (First .. Ranges'Last), ",") - 1;
         end if;

         Send_Range (Ranges (First .. Last));
         First := Last + 2;
      end loop;

      --  End the multipart/byteranges message

      if N_Range /= 1 then
         --  Send the multipart/byteranges
         Send ("--" & Boundary & "--" & CRLF, Last_One => True);
      end if;
   end Send_File_Ranges_G;

   -------------------
   -- Send_Resource --
   -------------------

   procedure Send_Resource
     (Answer      : in out Response.Data;
      File        : in out Resources.File_Type;
      Length      : in out Resources.Content_Length_Type;
      HTTP_Server : access AWS.Server.HTTP;
      Line_Index  : Positive;
      C_Stat      : AWS.Status.Data)
   is
      use type Status.Request_Method;

      Sock        : constant Net.Socket_Type'Class := Status.Socket (C_Stat);

      Method      : constant AWS.Status.Request_Method :=
                      Status.Method (C_Stat);

      Chunk_Size  : constant := 1_024;
      --  Size of the buffer used to send the file with the chunked encoding.
      --  This is the maximum size of each chunk.

      Ranges      : constant String :=
                      Headers.Get_Values
                        (Status.Header (C_Stat), Messages.Range_Token);
      --  The ranges for partial sending if defined

      Close       : constant Boolean := Response.Close_Resource (Answer);

      procedure Send_File;
      --  Send file in one part

      procedure Send_Ranges;
      --  Send a set of ranges of file content

      procedure Send_File_Chunked;
      --  Send file in chunks, used in HTTP/1.1 and when the message length
      --  is not known)

      procedure Data_Received
        (Content   : Stream_Element_Array;
         Next_Size : in out Stream_Element_Count);
      --  New data received

      Last : Streams.Stream_Element_Offset;

      -------------------
      -- Data_Received --
      -------------------

      procedure Data_Received
        (Content   : Stream_Element_Array;
         Next_Size : in out Stream_Element_Count)
      is
         pragma Unreferenced (Next_Size);
      begin
         Net.Buffered.Write (Sock, Content);
      end Data_Received;

      procedure Send_File_Content is new Send_File_G (Data_Received);

      ---------------
      -- Send_File --
      ---------------

      procedure Send_File is
      begin
         Send_File_Content
           (HTTP_Server, Line_Index, File, 1,
            Chunk_Size => 4 * 1024,
            Length     => Length);
      end Send_File;

      ---------------------
      -- Send_File_Chunk --
      ---------------------

      procedure Send_File_Chunked is
         --  Note that we do not use a buffered socket here. Opera on SSL
         --  sockets does not like chunk that are not sent in a whole.

         Buffer     : Streams.Stream_Element_Array (1 .. Chunk_Size);
         --  Each chunk will have a maximum length of Buffer'Length

         CRLF       : constant Streams.Stream_Element_Array :=
                        [1 => Character'Pos (ASCII.CR),
                         2 => Character'Pos (ASCII.LF)];

         Last_Chunk : constant Streams.Stream_Element_Array :=
                        Character'Pos ('0') & CRLF & CRLF;
         --  Last chunk for a chunked encoding stream. See [RFC 2616 - 3.6.1]

      begin
         Send_Chunks : loop
            Resources.Read (File, Buffer, Last);

            if Last = 0 then
               --  There is not more data to read, the previous chunk was the
               --  last one, just terminate the chunk message here.
               Net.Send (Sock, Last_Chunk);
               exit Send_Chunks;
            end if;

            Length := Length + Last;

            HTTP_Server.Slots.Check_Data_Timeout (Line_Index);

            declare
               H_Last : constant String := Utils.Hex (Positive (Last));

               Chunk  : constant Streams.Stream_Element_Array :=
                          Translator.To_Stream_Element_Array (H_Last)
                          & CRLF & Buffer (1 .. Last) & CRLF;
               --  A chunk is composed of:
               --     the Size of the chunk in hexadecimal
               --     a line feed
               --     the chunk
               --     a line feed

            begin
               --  Check if the last data portion

               if Last < Buffer'Last then
                  --  No more data, add the terminating chunk
                  Net.Send (Sock, Chunk & Last_Chunk);
                  exit Send_Chunks;
               else
                  Net.Send (Sock, Chunk);
               end if;
            end;
         end loop Send_Chunks;
      end Send_File_Chunked;

      -----------------
      -- Send_Ranges --
      -----------------

      procedure Send_Ranges is
         procedure Send_Ranges_Content is
           new Send_File_Ranges_G (Data_Received, Send_File_Content, False);
      begin
         Send_Ranges_Content
           (HTTP_Server, Line_Index, File, Ranges, 4096, Length, Answer);
      end Send_Ranges;

   begin
      if Ranges /= "" and then Length /= Resources.Undefined_Length then
         --  Range: header present, we need to send only the specified bytes

         Net.Buffered.Put_Line
           (Sock, Messages.Accept_Ranges_Token & ": bytes");
         --  Only bytes supported

         Send_Ranges;

      elsif Status.HTTP_Version (C_Stat) = HTTP_10
        or else Length /= Resources.Undefined_Length
      then
         Net.Buffered.Put_Line
           (Sock, Messages.Content_Type (Response.Content_Type (Answer)));

         --  If content length is undefined and we handle an HTTP/1.0 protocol
         --  then the end of the stream will be determined by closing the
         --  connection. [RFC 1945 - 7.2.2] See the Will_Close local variable.

         if Length /= Resources.Undefined_Length
           and then not Response.Has_Header
                          (Answer, Messages.Content_Length_Token)
         then
            Net.Buffered.Put_Line (Sock, Messages.Content_Length (Length));
         end if;

         --  Terminate header

         Net.Buffered.New_Line (Sock);

         if Method /= Status.HEAD and then Length /= 0 then
            Length := 0;
            Send_File;
         end if;

      else
         Net.Buffered.Put_Line
           (Sock, Messages.Content_Type (Response.Content_Type (Answer)));

         --  HTTP/1.1 case and we do not know the message length
         --
         --  Terminate header, do not send the Content_Length see
         --  [RFC 2616 - 4.4]. It could be possible to send the Content_Length
         --  as this is cleary a permission but it does not work in some
         --  obsucre cases.

         Net.Buffered.Put_Line (Sock, Messages.Transfer_Encoding ("chunked"));
         Net.Buffered.New_Line (Sock);
         Net.Buffered.Flush (Sock);

         --  Past this point we will not use the buffered mode. Opera on SSL
         --  sockets does not like chunk that are not sent in a whole.

         if Method /= Status.HEAD then
            Length := 0;
            Send_File_Chunked;
         end if;
      end if;

      if Close then
         Resources.Close (File);
      end if;
   exception
      when others =>
         if Close then
            Resources.Close (File);
         end if;
         raise;
   end Send_Resource;

   ----------------------
   -- Set_Close_Status --
   ----------------------

   procedure Set_Close_Status
     (C_Stat     : AWS.Status.Data;
      Keep_Alive : Boolean;
      Will_Close : in out Boolean)
   is
      Connection : constant String := Status.Connection (C_Stat);
   begin
      --  Connection, check connection string with Match to skip connection
      --  options [RFC 2616 - 14.10].

      Will_Close := Utils.Match (Connection, "close")
        or else not Keep_Alive
        or else (Status.HTTP_Version (C_Stat) = HTTP_10
                 and then not Utils.Match (Connection, "keep-alive"));
   end Set_Close_Status;

   ----------------
   -- Split_Path --
   ----------------

   procedure Split_Path
     (Path                   : String;
      Path_Last, Query_First : out Positive)
   is
      Delimiter : Natural := Fixed.Index (Path, "?");
   begin
      if Delimiter /= 0 then
         Path_Last   := Delimiter - 1;
         Query_First := Delimiter + 1;
         return;
      end if;

      --  ? Could be encoded %3f

      Delimiter := Fixed.Index (Path, "%3f");

      if Delimiter = 0 then
         Delimiter := Fixed.Index (Path, "%3F");
      end if;

      if Delimiter = 0 then
         Query_First := Path'Last + 1;
         Path_Last   := Path'Last;
      else
         Query_First := Delimiter + 3;
         Path_Last   := Delimiter - 1;
      end if;
   end Split_Path;

end AWS.Server.HTTP_Utils;
