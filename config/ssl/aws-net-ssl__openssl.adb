------------------------------------------------------------------------------
--                              Ada Web Server                              --
--                                                                          --
--                     Copyright (C) 2000-2025, AdaCore                     --
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

pragma Ada_2022;

--  Routines here are wrappers around standard sockets and SSL.
--
--  IMPORTANT: The default certificate used for the SSL connection is
--  "cert.pem" (in the working directory) if it exists. If this file does
--  not exists it is required to initialize the SSL layer certificate with
--  AWS.Server.Set_Security.

with Ada.Command_Line;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Indefinite_Holders;
with Ada.Directories;
with Ada.Strings.Equal_Case_Insensitive;
with Ada.Strings.Hash_Case_Insensitive;
with Ada.Task_Attributes;
with Ada.Task_Identification;
with Ada.Task_Termination;
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with Interfaces.C.Strings;

with System.Memory;
with System.Storage_Elements;

with AWS.Net.Log;
with AWS.Net.SSL.Certificate.Impl;
with AWS.Net.SSL.Common;
with AWS.Net.SSL.RSA_DH_Generators;
with AWS.OS_Lib;
with AWS.Translator;
with AWS.Utils;

with GNAT.String_Split;

package body AWS.Net.SSL is

   use Ada.Strings;
   use Interfaces;
   use type C.int;
   use type C.long;
   use type TSSL.Pointer;
   use type TSSL.SSL_CTX;
   use type TSSL.SSL_Handle;

   subtype NSST is Net.Std.Socket_Type;

   package Locking is

      procedure Initialize;
      --  Initialize OpenSSL version less 1.1 locking callbacks, this makes
      --  OpenSSL implementation thread safe.

   end Locking;

   function Lib_Realloc
     (Ptr  : System.Address;
      Size : System.Memory.size_t) return System.Address with Convention => C;
   --  C library could use null pointer as input parameter for realloc, but
   --  gnatmem does not care about it and logging Free of the null pointer.

   function BIO_Debug_Write
     (BIO  : TSSL.BIO_Access;
      Buf  : C.Strings.chars_ptr;
      Size : C.int) return C.int with Convention => C;

   Debug_BIO_Method : TSSL.BIO_Method_Access;
   Debug_BIO_Output : TSSL.BIO_Access;

   package Host_Certificates is new Ada.Containers.Indefinite_Hashed_Maps
     (String, TSSL.SSL_CTX,
      Hash            => Hash_Case_Insensitive,
      Equivalent_Keys => Equal_Case_Insensitive);

   package Char_Array_Holder is new Ada.Containers.Indefinite_Holders
     (C.char_array, "=" => C."=");

   procedure Set_Session_Cache_Size (Context : TSSL.SSL_CTX; Size : Integer);
   --  Check the session cache size for specified context. Check error codes
   --  and raise exception on errors.

   function To_Char_Array (Protocols : SV.Vector) return C.char_array;
   --  Converts Protocols to OpenSSL library protocol-list format

   function To_Char_Array (Protocol : String) return C.char_array is
     (C."&" (C.char'Val (Protocol'Length), C.To_C (Protocol, False)));
   --  Converts Protocol to OpenSSL library protocol name format

   function ALPN_Callback
     (SSL    : TSSL.SSL_Handle;
      Out_Pr : access C.Strings.chars_ptr;
      Outlen : access C.unsigned_char;
      In_Pr  : C.Strings.chars_ptr;
      Inlen  : C.unsigned;
      Arg    : TSSL.Pointer) return C.int with Convention => C;

   type Meth_Func is access function return TSSL.SSL_Method
     with Convention => C;

   protected type TS_SSL is

      procedure Set_IO (Socket : in out Socket_Type);
      --  Bind the SSL handle with the BIO pair

      procedure Initialize
        (Security_Mode         : Method;
         Server_Certificate    : String;
         Server_Key            : String;
         Client_Certificate    : String;
         Priorities            : String;
         Ticket_Support        : Boolean;
         Exchange_Certificate  : Boolean;
         Check_Certificate     : Boolean;
         Trusted_CA_Filename   : String;
         CRL_Filename          : String;
         Session_Cache_Size    : Natural;
         ALPN                  : C.char_array;
         SSL_Handshake_Timeout : Duration);

      procedure Prepare
        (Security_Mode        : Method;
         Priorities           : String;
         Ticket_Support       : Boolean;
         Exchange_Certificate : Boolean;
         Check_Certificate    : Boolean;
         Trusted_CA_Filename  : String;
         CRL_Filename         : String;
         Session_Cache_Size   : Natural);

      procedure Initialize_Client_Certificate
        (Host                 : String;
         Certificate_Filename : String);

      procedure Initialize_Host_Certificate
        (Host                 : String;
         Certificate_Filename : String;
         Key_Filename         : String);

      procedure ALPN_Set (Protos : C.char_array);

      procedure ALPN_Include (Protocol : String);

      procedure Finalize;

      procedure Clear_Session_Cache;

      procedure Set_Session_Cache_Size (Size : Natural);

      function Session_Cache_Number return Natural;

      procedure Set_Trusted_CA_Certificate (Context : TSSL.SSL_CTX);

      procedure Set_Verify_Callback (Callback : System.Address);

      procedure Check_CRL;
      --  Check Certificate Revocation List, if this file has changed reload it

      function Get_Check_Certificate return Boolean;

      function Get_Context return TSSL.SSL_CTX;

      function Get_Handshake_Timeout return Duration;

      procedure New_SSL (Socket : in out Socket_Type);

   private
      Default_Context : TSSL.SSL_CTX        := TSSL.Null_CTX;
      CRL_Filename    : C.Strings.chars_ptr := C.Strings.Null_Ptr;
      CRL_Time_Stamp  : Calendar.Time       := Utils.AWS_Epoch;

      Hosts : Host_Certificates.Map;

      Security_Mode        : Method;
      Ticket_Support       : Boolean;
      Exchange_Certificate : Boolean;
      Check_Certificate    : Boolean;
      Session_Cache_Size   : Natural;
      Priorities           : C.Strings.chars_ptr;
      Prio_TLS13           : C.Strings.chars_ptr;
      ALPN                 : Char_Array_Holder.Holder;
      Trusted_CA_Filename  : C.Strings.chars_ptr;
      Trusted_CA_Stack     : TSSL.STACK_OF_X509_NAME :=
                               TSSL.Null_STACK_OF_X509_NAME;
      Handshake_Timeout    : Duration := AWS.Net.Forever;
   end TS_SSL;

   function Server_Name_Callback
     (Session : SSL_Handle;
      ad      : access C.int; -- documentation not found
      Hosts   : access Host_Certificates.Map) return C.int
     with Convention => C;
   --  Callback to get server name on server side as client sent

   type Memory_Access is access all
     Stream_Element_Array (1 .. Stream_Element_Offset'Last);

   Default_Client_Config : Config;
   Default_Server_Config : Config;

   Data_Index   : C.int;
   --  Application specific data's index

   Max_Overhead : Stream_Element_Count range 0 .. 2**15 := 180
     with Atomic, Size => 16;
   --  Need size limitation because Stream_Element_Count is 64 bit and could
   --  not guarantee Atomic on 32 bit platform.

   Debug_Level : Natural := 0 with Atomic;

   DH_Params  : array (0 .. 1) of aliased TSSL.DH :=
                  [others => TSSL.Null_Pointer] with Atomic_Components;
   RSA_Params : array (0 .. 1) of aliased TSSL.RSA :=
                  [others => TSSL.Null_Pointer] with Atomic_Components;
   --  0 element for current use, 1 element for remain usage after creation new
   --  0 element.

   DH_Length  : constant C.int := 2048;
   RSA_Length : constant C.int := 2048;

   function DH_Generate_cb
     (a, b : C.int; cb : access TSSL.BN_GENCB) return C.int
     with Convention => C;

   DH_Generate_Callback : aliased TSSL.BN_GENCB :=
     (cb => DH_Generate_cb'Access, others => <>);

   procedure Socket_Read (Socket : Socket_Type);
   --  Read encripted data from socket if necessary

   procedure Socket_Write (Socket : Socket_Type; Gone : C.int := 0);
   --  Write encripted data to socket if availabe

   procedure Error_If (Error : Boolean) with Inline;
   --  Raises Socket_Error if Error is true. Attach the SSL error message

   procedure Error_If (Socket : Socket_Type; Error : Boolean) with Inline;
   --  Raises and log Socket_Error if Error is true.
   --  Attach the SSL error message.

   procedure File_Error (Prefix, Name : String) with No_Return;
   --  Prefix is the type of file key or certificate that was expected

   procedure Do_Handshake (Socket : in out Socket_Type; Success : out Boolean);
   --  Perform SSL handshake

   function Error_Stack return String renames Certificate.Impl.Error_Stack;
   --  Returns error stack of the last SSL error in multiple lines

   function Error_Str (Code : TSSL.Error_Code) return String
     renames Certificate.Impl.Error_Str;
   --  Returns the SSL error message for error Code

   procedure Init_Random;
   --  Initialize the SSL library with a random number

   function Verify_Callback
     (preverify_ok : C.int; ctx : TSSL.X509_STORE_CTX) return C.int
     with Convention => C;
   --  This routine is needed to be able to retreive the client's certificate
   --  and validate it thought the user's verification routine if provided.

   function Tmp_RSA_Callback
     (SSL : SSL_Handle; Is_Export : C.int; Keylength : C.int) return TSSL.RSA
     with Convention => C;

   function Tmp_DH_Callback
     (SSL : SSL_Handle; Is_Export : C.int; Keylength : C.int) return TSSL.DH
     with Convention => C;

   procedure Secure
     (Source : Net.Socket_Type'Class;
      Target : out Socket_Type;
      Config : SSL.Config;
      Server : Boolean);
   --  Common code for Secure_Server and Secure_Client routines

   procedure Set_Accept_State (Socket : Socket_Type);
   --  Server session initialization

   procedure Set_Connect_State (Socket : Socket_Type; Host : String);
   --  Client session initialization

   -------------------------
   -- Abort_DH_Generation --
   -------------------------

   procedure Abort_DH_Generation is
   begin
      Abort_DH_Flag := True;
   end Abort_DH_Generation;

   -------------------
   -- Accept_Socket --
   -------------------

   overriding procedure Accept_Socket
     (Socket : Net.Socket_Type'Class; New_Socket : in out Socket_Type)
   is
      Success : Boolean;
   begin
      if New_Socket.Config = null then
         New_Socket.Config := Get_Default_Server_Config;
      end if;

      SSL_Accept : loop
         Net.Std.Accept_Socket (Socket, NSST (New_Socket));

         New_Socket.Config.New_SSL (New_Socket);

         New_Socket.Config.Set_IO (New_Socket);

         Set_Accept_State (New_Socket);

         Do_Handshake (New_Socket, Success);

         exit SSL_Accept when Success;

         Shutdown (New_Socket);
      end loop SSL_Accept;
   end Accept_Socket;

   --------------------------
   -- Add_Host_Certificate --
   --------------------------

   procedure Add_Host_Certificate
     (Config               : SSL.Config;
      Host                 : String;
      Certificate_Filename : String;
      Key_Filename         : String := "") is
   begin
      Config.Initialize_Host_Certificate
        (Host, Certificate_Filename, Key_Filename);
   end Add_Host_Certificate;

   -------------------
   -- ALPN_Callback --
   -------------------

   function ALPN_Callback
     (SSL    : TSSL.SSL_Handle;
      Out_Pr : access C.Strings.chars_ptr;
      Outlen : access C.unsigned_char;
      In_Pr  : C.Strings.chars_ptr;
      Inlen  : C.unsigned;
      Arg    : TSSL.Pointer) return C.int
   is
      pragma Unreferenced (SSL);
      ALPN   : Char_Array_Holder.Holder with Import;
      for ALPN'Address use Arg;
      Server : constant C.Strings.char_array_access :=
                 ALPN.Reference.Element;
   begin
      if TSSL.SSL_select_next_proto
        (Out_Pr, Outlen, C.Strings.To_Chars_Ptr (Server), Server'Length, In_Pr,
         Inlen) /= TSSL.OPENSSL_NPN_NEGOTIATED
      then
         Outlen.all := 0;
      end if;

      return TSSL.SSL_TLSEXT_ERR_OK;
   end ALPN_Callback;

   --------------
   -- ALPN_Set --
   --------------

   function ALPN_Get (Socket : Socket_Type) return String is
      use type C.unsigned, C.Strings.chars_ptr;
      Data : aliased C.Strings.chars_ptr;
      Size : aliased C.unsigned;
   begin
      TSSL.SSL_get0_alpn_selected (Socket.SSL, Data'Access, Size'Access);

      if Data = C.Strings.Null_Ptr or else Size = 0 then
         return "";
      end if;

      return C.Strings.Value (Data, C.size_t (Size));
   end ALPN_Get;

   ------------------
   -- ALPN_Include --
   ------------------

   procedure ALPN_Include (Config : SSL.Config; Protocol : String) is
   begin
      Config.ALPN_Include (Protocol);
   end ALPN_Include;

   --------------
   -- ALPN_Set --
   --------------

   procedure ALPN_Set (Config : SSL.Config; Protocols : SV.Vector) is
   begin
      Config.ALPN_Set (To_Char_Array (Protocols));
   end ALPN_Set;

   ---------------------
   -- BIO_Debug_Write --
   ---------------------

   function BIO_Debug_Write
     (BIO  : TSSL.BIO_Access;
      Buf  : C.Strings.chars_ptr;
      Size : C.int) return C.int
   is
      pragma Unreferenced (BIO);
   begin
      Debug_Output (C.Strings.Value (Buf, C.size_t (Size)));
      return Size;
   end BIO_Debug_Write;

   ------------------------
   -- Cipher_Description --
   ------------------------

   overriding function Cipher_Description
     (Socket : Socket_Type) return String
   is
      Buffer : aliased C.char_array := [1 .. 256 => <>];
      Result : constant String :=
                 C.Strings.Value
                   (TSSL.SSL_CIPHER_description
                      (TSSL.SSL_get_current_cipher (Socket.SSL).all,
                       Buffer'Unchecked_Access, Buffer'Length));
   begin
      if Result'Length > 0 and then Result (Result'Last) = ASCII.LF then
         return Result (Result'First .. Result'Last - 1);
      end if;

      return Result;
   end Cipher_Description;

   -------------
   -- Ciphers --
   -------------

   procedure Ciphers (Cipher : not null access procedure (Name : String)) is
      use type C.Strings.chars_ptr;
      Name : C.Strings.chars_ptr;
      Ctx  : constant TSSL.SSL_CTX := TSSL.SSL_CTX_new (TSSL.TLS_method);
      SSL  : SSL_Handle;
   begin
      Error_If (Ctx = TSSL.Null_CTX);

      SSL := TSSL.SSL_new (Ctx);
      Error_If (SSL = TSSL.Null_Handle);

      for J in 0 .. C.int'Last loop
         Name := TSSL.SSL_get_cipher_list (SSL, J);
         exit when Name = C.Strings.Null_Ptr;
         Cipher (C.Strings.Value (Name));
      end loop;

      TSSL.SSL_free (SSL);
      TSSL.SSL_CTX_free (Ctx);
   end Ciphers;

   -------------------------
   -- Clear_Session_Cache --
   -------------------------

   procedure Clear_Session_Cache (Config : SSL.Config := Null_Config) is
   begin
      if Config = Null_Config then
         Default_Client_Config.Clear_Session_Cache;
         Default_Server_Config.Clear_Session_Cache;
      else
         Config.Clear_Session_Cache;
      end if;
   end Clear_Session_Cache;

   -------------
   -- Connect --
   -------------

   overriding procedure Connect
     (Socket : in out Socket_Type;
      Host   : String;
      Port   : Positive;
      Wait   : Boolean     := True;
      Family : Family_Type := Family_Unspec)
   is
      Success : Boolean;
      Res     : C.int;
   begin
      Net.Std.Connect (NSST (Socket), Host, Port, Wait, Family);

      if Socket.Config = null then
         Socket.Config := Get_Default_Client_Config;
      end if;

      Socket.Config.New_SSL (Socket);

      if Socket.Config.Get_Check_Certificate then
         --  Enable hostname validation
         declare
            H_Str : C.Strings.chars_ptr := C.Strings.New_String (Host);
         begin
            TSSL.SSL_set_hostflags
              (Socket.SSL, TSSL.X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);

            Res := TSSL.SSL_set1_host (Socket.SSL, H_Str);

            if Res = 0 then
               Raise_Socket_Error (Socket, "cannot set host : " & Host);
            end if;

            C.Strings.Free (H_Str);
         end;
      end if;

      Socket.Config.Set_IO (Socket);

      if Socket.Sessn /= null then
         Set_Session_Data (Socket, Socket.Sessn);
         Socket.Sessn := null;
      end if;

      Set_Connect_State (Socket, Host);

      if Wait then
         --  Do handshake only in case of wait connection completion

         Do_Handshake (Socket, Success);

         if not Success then
            declare
               Error_Text : constant String := Error_Stack;
            begin
               Net.Log.Error (Socket, Error_Text);

               Net.Std.Shutdown (NSST (Socket));

               raise Socket_Error with Error_Text;
            end;
         end if;
      end if;
   end Connect;

   --------------------
   -- DH_Generate_cb --
   --------------------

   function DH_Generate_cb
     (a, b : C.int; cb : access TSSL.BN_GENCB) return C.int
   is
      pragma Unreferenced (a, b, cb);
   begin
      return Boolean'Pos (not Abort_DH_Flag);
   end DH_Generate_cb;

   ------------------
   -- Do_Handshake --
   ------------------

   procedure Do_Handshake
     (Socket : in out Socket_Type; Success : out Boolean)
   is
      use TSSL;
      Res  : C.int;
      SRes : C.long;
   begin
      Success := False;
      Socket.Set_Timeout (Socket.Config.Get_Handshake_Timeout);

      loop
         Res := SSL_do_handshake (Socket.SSL);

         Success := Res = 1;

         exit when Success;

         case SSL_get_error (Socket.SSL, Res) is
            when SSL_ERROR_WANT_READ  => Socket_Read (Socket);
            when SSL_ERROR_WANT_WRITE => Socket_Write (Socket);
            when others               => exit;
         end case;
      end loop;

      if Success and then Socket.Config.Get_Check_Certificate then
         --  And also check SSL context

         SRes := SSL_get_verify_result (Socket.SSL);

         if SRes /= X509_V_OK then
            declare
               Err : constant Cstr.chars_ptr :=
                       X509_verify_cert_error_string (SRes);
            begin
               Raise_Socket_Error
                 (Socket, "certificate verification error : ("
                  & AWS.Utils.Image (Natural (SRes)) & ") "
                  & Cstr.Value (Err));
            end;
         end if;
      end if;

      Socket_Write (Socket);
   end Do_Handshake;

   procedure Do_Handshake (Socket : in out Socket_Type) is
      Success : Boolean;
   begin
      Do_Handshake (Socket, Success);

      if not Success then
         Raise_Socket_Error (Socket, Error_Stack);
      end if;
   end Do_Handshake;

   --------------
   -- Error_If --
   --------------

   procedure Error_If (Error : Boolean) is
   begin
      if Error then
         Raise_Socket_Error
           (Socket_Type'(Std.Socket_Type with others => <>), Error_Stack);
      end if;
   end Error_If;

   procedure Error_If (Socket : Socket_Type; Error : Boolean) is
   begin
      if Error then
         Raise_Socket_Error (Socket, Error_Stack);
      end if;
   end Error_If;

   ----------------
   -- File_Error --
   ----------------

   procedure File_Error (Prefix, Name : String) is
   begin
      raise Socket_Error with
         Prefix & " file """ & Name & """ error." & ASCII.LF & Error_Stack;
   end File_Error;

   ----------
   -- Free --
   ----------

   overriding procedure Free (Socket : in out Socket_Type) is
   begin
      if Socket.SSL /= TSSL.Null_Handle then
         TSSL.SSL_free (Socket.SSL);
         TSSL.BIO_free (Socket.IO);
         Socket.SSL := TSSL.Null_Handle;
      end if;

      NSST (Socket).Free;
   end Free;

   ----------
   -- Free --
   ----------

   procedure Free (Session : in out Session_Type) is
   begin
      if Session /= null then
         TSSL.SSL_SESSION_free (TSSL.SSL_Session (Session));
         Session := null;
      end if;
   end Free;

   procedure Free (Key : in out Private_Key) is
   begin
      if Key /= Null_Private_Key then
         EVP_PKEY_free (Key);
         Key := Null_Private_Key;
      end if;
   end Free;

   -----------------
   -- Generate_DH --
   -----------------

   procedure Generate_DH is

      use type TSSL.BIO_Access;

      OK   : Boolean;
      DH   : aliased TSSL.DH;
      Bits : constant C.int := DH_Length;

      function Loaded return Boolean;

      procedure Save;

      ------------
      -- Loaded --
      ------------

      function Loaded return Boolean is
         Filename : constant String :=
                      RSA_DH_Generators.Parameters_Filename
                        ("dh-" & Utils.Image (Integer (Bits)), Exist => True);
         C_Name   : aliased C.char_array := C.To_C (Filename);
         IO       : TSSL.BIO_Access;
      begin
         if Filename = "" then
            return False;
         end if;

         IO := TSSL.BIO_new (TSSL.BIO_s_file);

         Error_If (IO = null);
         Error_If
           (TSSL.BIO_read_filename
              (IO, C.Strings.To_Chars_Ptr (C_Name'Unchecked_Access)) = 0);

         Error_If
           (TSSL.PEM_read_bio_DHparams (IO, DH'Access, null, TSSL.Null_Pointer)
            /= DH);

         DH_Time_Idx := @ + 1;
         DH_Time (DH_Time_Idx) :=
           Ada.Directories.Modification_Time (Filename);

         TSSL.BIO_free (IO);

         return True;
      end Loaded;

      ----------
      -- Save --
      ----------

      procedure Save is
         Filename : constant String :=
                      RSA_DH_Generators.Parameters_Filename
                        ("dh-" & Utils.Image (Integer (Bits)), Exist => False);
         C_Name   : aliased C.char_array := C.To_C (Filename);
         BIO      : TSSL.BIO_Access;
      begin
         if Filename = "" then
            return;
         end if;

         BIO := TSSL.BIO_new (TSSL.BIO_s_file);

         Error_If (BIO = null);
         Error_If
           (TSSL.BIO_write_filename
              (BIO, C.Strings.To_Chars_Ptr (C_Name'Unchecked_Access)) = 0);

         Error_If (TSSL.PEM_write_bio_DHparams (BIO, DH) = 0);

         TSSL.BIO_free (BIO);
      end Save;

   begin
      DH_Lock.Try_Lock (OK);

      if not OK then
         return;
      end if;

      DH := TSSL.DH_new;

      Error_If (DH = TSSL.Null_Pointer);

      if DH_Params (0) /= TSSL.Null_Pointer or else not Loaded then
         if TSSL.DH_generate_parameters_ex
              (params    => DH,
               prime_len => DH_Length,
               generator => (if DH_Time_Idx = 0 then 2 else 5),
               cb        => DH_Generate_Callback'Access) = 0
         then
            Error_If (not Abort_DH_Flag);
         else
            DH_Time_Idx := @ + 1;
            DH_Time (DH_Time_Idx) := Ada.Calendar.Clock;

            Save;
         end if;
      end if;

      if DH_Params (1) /= TSSL.Null_Pointer then
         TSSL.DH_free (DH_Params (1));
      end if;

      DH_Params (1) := DH_Params (0);
      DH_Params (0) := DH;

      DH_Lock.Unlock;
   end Generate_DH;

   ------------------
   -- Generate_RSA --
   ------------------

   procedure Generate_RSA is
      OK  : Boolean;
      BN  : TSSL.BIGNUM;
      RSA : TSSL.RSA;
   begin
      RSA_Lock.Try_Lock (OK);

      if not OK then
         return;
      end if;

      BN := TSSL.BN_new;

      Error_If (TSSL."=" (BN, TSSL.BIGNUM (TSSL.Null_Pointer)));
      Error_If (TSSL.BN_set_word (BN, TSSL.RSA_F4) = 0);

      RSA := TSSL.RSA_new;

      Error_If (RSA = TSSL.Null_Pointer);
      Error_If
        (TSSL.RSA_generate_key_ex
           (RSA, RSA_Length, BN, TSSL.Null_Pointer) = 0);

      TSSL.BN_free (BN);

      if RSA_Params (1) /= TSSL.Null_Pointer then
         TSSL.RSA_free (RSA_Params (1));
      end if;

      RSA_Params (1) := RSA_Params (0);
      RSA_Params (0) := RSA;

      RSA_Time_Idx := @ + 1;
      RSA_Time (RSA_Time_Idx) := Ada.Calendar.Clock;

      RSA_Lock.Unlock;
   end Generate_RSA;

   ---------------------------
   -- Get_Check_Certificate --
   ---------------------------

   function Get_Check_Certificate (Config : SSL.Config) return Boolean is
   begin
      return Config.Get_Check_Certificate;
   end Get_Check_Certificate;

   -------------------------------
   -- Get_Default_Client_Config --
   -------------------------------

   function Get_Default_Client_Config return SSL.Config is
      Config : SSL.Config renames Default_Client_Config;
      D      : SSL_Data renames Default_Data;
   begin
      if Config = null then
         Config := new TS_SSL;

         Config.Initialize
           (Security_Mode         =>
              Common.Get_Client_Method (D.Security_Mode),
            Server_Certificate    => "",
            Server_Key            => "",
            Client_Certificate    => -D.Client_Certificate,
            Priorities            => -D.Priorities,
            Ticket_Support        => D.Ticket_Support,
            Exchange_Certificate  => D.Exchange_Certificate,
            Check_Certificate     => D.Check_Certificate,
            Trusted_CA_Filename   => -D.Trusted_CA_Filename,
            CRL_Filename          => -D.CRL_Filename,
            Session_Cache_Size    => D.Session_Cache_Size,
            ALPN                  => To_Char_Array (D.ALPN),
            SSL_Handshake_Timeout => D.SSL_Handshake_Timeout);
      end if;

      return Config;
   end Get_Default_Client_Config;

   function Get_Default_Server_Config return SSL.Config is
      Config : SSL.Config renames Default_Server_Config;
      D      : SSL_Data renames Default_Data;
   begin
      if Config = null then
         Config := new TS_SSL;

         Config.Initialize
           (Security_Mode         =>
              Common.Get_Server_Method (D.Security_Mode),
            Server_Certificate    => -D.Server_Certificate,
            Server_Key            => -D.Server_Key,
            Client_Certificate    => "",
            Priorities            => -D.Priorities,
            Ticket_Support        => D.Ticket_Support,
            Exchange_Certificate  => D.Exchange_Certificate,
            Check_Certificate     => D.Check_Certificate,
            Trusted_CA_Filename   => -D.Trusted_CA_Filename,
            CRL_Filename          => -D.CRL_Filename,
            Session_Cache_Size    => D.Session_Cache_Size,
            ALPN                  => To_Char_Array (D.ALPN),
            SSL_Handshake_Timeout => D.SSL_Handshake_Timeout);
      end if;

      return Config;
   end Get_Default_Server_Config;

   -----------------
   -- Init_Random --
   -----------------

   procedure Init_Random is
      use Ada.Calendar;
      use System.Storage_Elements;

      Buf : String :=
              Duration'Image
                (Clock - Time_Of (Year  => Year_Number'First,
                                  Month => Month_Number'First,
                                  Day   => Day_Number'First))
              & Integer_Address'Image (To_Integer (Init_Random'Address));
   begin
      TSSL.RAND_seed (Buf'Address, Buf'Length);
   end Init_Random;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize
     (Config               : in out SSL.Config;
      Security_Mode        : Method    := TLS;
      Server_Certificate   : String    := "";
      Server_Key           : String    := "";
      Client_Certificate   : String    := "";
      Priorities           : String    := "";
      Ticket_Support       : Boolean   := False;
      Exchange_Certificate : Boolean   := False;
      Check_Certificate    : Boolean   := True;
      Trusted_CA_Filename  : String    := "";
      CRL_Filename         : String    := "";
      Session_Cache_Size   : Natural   := 16#4000#;
      ALPN                 : SV.Vector := SV.Empty_Vector;
      SSL_Handshake_Timeout : Duration := AWS.Net.Forever) is
   begin
      if Config = null then
         Config := new TS_SSL;
      end if;

      Config.Initialize
        (Security_Mode, Server_Certificate, Server_Key, Client_Certificate,
         Priorities, Ticket_Support,
         Exchange_Certificate, Check_Certificate,
         Trusted_CA_Filename, CRL_Filename, Session_Cache_Size,
         To_Char_Array (ALPN), SSL_Handshake_Timeout);
   end Initialize;

   -------------------------------
   -- Initialize_Default_Config --
   -------------------------------

   procedure Initialize_Default_Config
     (Security_Mode         : Method    := TLS;
      Server_Certificate    : String    := Default.Server_Certificate;
      Server_Key            : String    := Default.Server_Key;
      Client_Certificate    : String    := Default.Client_Certificate;
      Priorities            : String    := "";
      Ticket_Support        : Boolean   := False;
      Exchange_Certificate  : Boolean   := False;
      Check_Certificate     : Boolean   := True;
      Trusted_CA_Filename   : String    := Default.Trusted_CA;
      CRL_Filename          : String    := "";
      Session_Cache_Size    : Natural   := 16#4000#;
      ALPN                  : SV.Vector := SV.Empty_Vector;
      SSL_Handshake_Timeout : Duration := AWS.Net.Forever) is
   begin
      Common.Initialize_Default_Config
        (Security_Mode, Server_Certificate, Server_Key,
         Client_Certificate, Priorities, Ticket_Support,
         Exchange_Certificate, Check_Certificate,
         Trusted_CA_Filename, CRL_Filename, Session_Cache_Size, ALPN,
         SSL_Handshake_Timeout);
   end Initialize_Default_Config;

   -----------------
   -- Lib_Realloc --
   -----------------

   function Lib_Realloc
     (Ptr  : System.Address;
      Size : System.Memory.size_t) return System.Address is
   begin
      if Ptr = System.Null_Address then
         return System.Memory.Alloc (Size);
      else
         return System.Memory.Realloc (Ptr, Size);
      end if;
   end Lib_Realloc;

   ----------
   -- Load --
   ----------

   function Load (Filename : String) return Private_Key is
      Key  : aliased Private_Key := EVP_PKEY_new;
      IO   : constant TSSL.BIO_Access := TSSL.BIO_new (TSSL.BIO_s_file);
      Name : aliased C.char_array := C.To_C (Filename);
      Pwd  : aliased C.char_array :=
               C.To_C (Net.SSL.Certificate.Get_Password (Filename));
   begin
      if TSSL.BIO_read_filename
           (IO, C.Strings.To_Chars_Ptr (Name'Unchecked_Access)) = 0
        or else PEM_read_bio_PrivateKey
                  (IO, Key'Access, null,
                   (if Pwd'Length <= 1       -- 1 means just the nul char
                    then TSSL.Null_Pointer
                    else Pwd'Address)) /= Key
      then
         TSSL.BIO_free (IO);
         EVP_PKEY_free (Key);
         File_Error ("Key", Filename);
      end if;

      TSSL.BIO_free (IO);

      return Key;
   end Load;

   ---------------
   -- Log_Error --
   ---------------

   procedure Log_Error (Text : String) is
   begin
      Log.Error (Socket_Type'(Net.Std.Socket_Type with others => <>), Text);
   end Log_Error;

   -------------
   -- Pending --
   -------------

   overriding function Pending
     (Socket : Socket_Type) return Stream_Element_Count
   is
      Res : constant C.int := TSSL.SSL_pending (Socket.SSL);
   begin
      Error_If (Socket, Res < 0);
      return Stream_Element_Count (Res);
   end Pending;

   -------------
   -- Receive --
   -------------

   overriding procedure Receive
     (Socket : Socket_Type;
      Data   : out Stream_Element_Array;
      Last   : out Stream_Element_Offset)
   is
      Len   : C.int;
      First : Stream_Element_Offset := Data'First;
   begin
      loop
         Len := TSSL.SSL_read
                  (Socket.SSL, Data (First)'Address,
                   Data'Length - C.int (First - Data'First));

         if Len > 0 then
            First := @ + Stream_Element_Offset (Len);
            Last  := First - 1;

            exit when Last = Data'Last;

         else
            exit when First > Data'First and then NSST (Socket).Pending = 0;

            case TSSL.SSL_get_error (Socket.SSL, Len) is
               when TSSL.SSL_ERROR_WANT_READ  => Socket_Read (Socket);
               when TSSL.SSL_ERROR_WANT_WRITE => Socket_Write (Socket);
               when TSSL.SSL_ERROR_SYSCALL =>
                  Raise_Socket_Error
                    (Socket,
                     "System error ("
                     & Utils.Image (OS_Lib.Socket_Errno)
                     & ") on SSL receive");

               when TSSL.SSL_ERROR_ZERO_RETURN =>
                  if Len = 0 then
                     raise Socket_Error with Peer_Closed_Message;
                  else
                     Raise_Socket_Error (Socket, Error_Stack);
                  end if;

               when others => Raise_Socket_Error (Socket, Error_Stack);
            end case;
         end if;
      end loop;
   end Receive;

   -------------
   -- Release --
   -------------

   procedure Release (Config : in out SSL.Config) is
      procedure Free is new Unchecked_Deallocation (TS_SSL, SSL.Config);
   begin
      if Config /= null
        and then Config not in Default_Client_Config | Default_Server_Config
      then
         Config.Finalize;
         Free (Config);
      end if;
   end Release;

   ------------
   -- Secure --
   ------------

   procedure Secure
     (Source : Net.Socket_Type'Class;
      Target : out Socket_Type;
      Config : SSL.Config;
      Server : Boolean) is
   begin
      Std.Socket_Type (Target) := Std.Socket_Type (Source);

      if Config = null then
         Target.Config := (if Server
                           then Get_Default_Server_Config
                           else Get_Default_Client_Config);
      else
         Target.Config := Config;
      end if;

      Target.Config.New_SSL (Target);
      Target.Config.Set_IO (Target);
   end Secure;

   -------------------
   -- Secure_Client --
   -------------------

   function Secure_Client
     (Socket : Net.Socket_Type'Class;
      Config : SSL.Config := Null_Config;
      Host   : String     := "") return Socket_Type is
   begin
      return Result : Socket_Type do
         Secure (Socket, Result, Config, False);
         Set_Connect_State (Result, Host);
      end return;
   end Secure_Client;

   -------------------
   -- Secure_Server --
   -------------------

   function Secure_Server
     (Socket : Net.Socket_Type'Class;
      Config : SSL.Config := Null_Config) return Socket_Type is
   begin
      return Result : Socket_Type do
         Secure (Socket, Result, Config, True);
         Set_Accept_State (Result);
      end return;
   end Secure_Server;

   ----------
   -- Send --
   ----------

   overriding procedure Send
     (Socket : Socket_Type;
      Data   : Stream_Element_Array;
      Last   : out Stream_Element_Offset)
   is
      RC        : C.int;
      RW        : constant RW_Data_Access := Net.Socket_Type (Socket).C;
      Pack_Size : Stream_Element_Count :=
                    Stream_Element_Count'Min (RW.Pack_Size, Data'Length);
   begin
      if not Check (Socket, [Input => False, Output => True]) (Output) then
         Last := Last_Index (Data'First, 0);
         return;
      end if;

      if not RW.Can_Wait then
         declare
            Free : constant Stream_Element_Offset := Socket.Output_Space;
         begin
            if Free > 0
              and then Pack_Size + Max_Overhead > Free
              and then Socket.Output_Busy > 0
            then
               if Free <= Max_Overhead then
                  Last := Last_Index (Data'First, 0);
                  return;
               else
                  Pack_Size := Free - Max_Overhead;
               end if;
            end if;
         end;
      end if;

      loop
         RC := TSSL.SSL_write (Socket.SSL, Data'Address, C.int (Pack_Size));

         if RC > 0 then
            if RC < C.int (Pack_Size) then
               --  Pack_Size initialization. This condition would be true only
               --  once per SSL socket.

               RW.Pack_Size := Stream_Element_Count (RC);
            end if;

            Socket_Write (Socket, RC);

            Last := Data'First + Stream_Element_Offset (RC) - 1;

            return;

         else
            declare
               Error_Code : constant C.int :=
                              TSSL.SSL_get_error (Socket.SSL, RC);

               Err_Code   : TSSL.Error_Code;
               Err_No     : Integer;

               use type TSSL.Error_Code;
            begin
               case Error_Code is
                  when TSSL.SSL_ERROR_WANT_READ =>
                     Socket_Read (Socket);

                  when TSSL.SSL_ERROR_WANT_WRITE =>
                     Socket_Write (Socket);

                  when TSSL.SSL_ERROR_SYSCALL =>
                     Err_No := OS_Lib.Socket_Errno;

                     if Err_No = 0 then
                        Socket_Write (Socket);
                        Last := Data'First - 1;

                        return;

                     else
                        Raise_Socket_Error
                          (Socket,
                           "System error (" & Utils.Image (Err_No)
                           & ") on SSL send");
                     end if;

                  when others =>
                     Err_Code := TSSL.ERR_get_error;

                     if Err_Code = 0 then
                        Raise_Socket_Error
                          (Socket,
                           "Error ("
                           & Utils.Image (Integer (Error_Code))
                           & ") on SSL send");
                     else
                        Raise_Socket_Error (Socket, Error_Str (Err_Code));
                     end if;
               end case;
            end;
         end if;
      end loop;
   end Send;

   --------------------------
   -- Server_Name_Callback --
   --------------------------

   function Server_Name_Callback
     (Session : SSL_Handle;
      ad      : access C.int; -- documentation not found
      Hosts   : access Host_Certificates.Map) return C.int
   is
      pragma Unreferenced (ad);
      use C.Strings;
      Server_Name : constant chars_ptr := TSSL.SSL_get_servername (Session);
      CH          : Host_Certificates.Cursor;
      Dummy       : TSSL.SSL_CTX;
   begin
      if Server_Name = Null_Ptr then
         return TSSL.SSL_TLSEXT_ERR_OK;
      end if;

      declare
         Host : constant String := Value (Server_Name);
      begin
         CH := Hosts.Find (Host);

         if not Host_Certificates.Has_Element (CH) then
            declare
               Wilded : constant String := Wildcard_Before_Dot (Host);
            begin
               if Wilded /= Host then
                  CH := Hosts.Find (Wilded);
               end if;
            end;
         end if;
      end;

      if Host_Certificates.Has_Element (CH) then
         Dummy := TSSL.SSL_set_SSL_CTX
           (Session, Host_Certificates.Element (CH));
      end if;

      return TSSL.SSL_TLSEXT_ERR_OK;

   exception
      when E : others =>
         Log_Error (Ada.Exceptions.Exception_Information (E));
         return TSSL.SSL_TLSEXT_ERR_ALERT_FATAL;
   end Server_Name_Callback;

   --------------------------
   -- Session_Cache_Number --
   --------------------------

   function Session_Cache_Number
     (Config : SSL.Config := Null_Config) return Natural is
   begin
      if Config /= null then
         return Config.Session_Cache_Number;
      elsif Default_Client_Config /= null then
         return Default_Client_Config.Session_Cache_Number;
      elsif Default_Server_Config /= null then
         return Default_Server_Config.Session_Cache_Number;
      else
         raise Constraint_Error with
           "Session_Cache_Size: no default config initialized";
      end if;
   end Session_Cache_Number;

   ------------------
   -- Session_Data --
   ------------------

   function Session_Data (Socket : Socket_Type) return Session_Type is
   begin
      return Session_Type (TSSL.SSL_get1_session (Socket.SSL));
   end Session_Data;

   ----------------------
   -- Session_Id_Image --
   ----------------------

   function Session_Id_Image (Session : Session_Type) return String is
      use TSSL;

      subtype Binary_Array is Stream_Element_Array (1 .. 1024);
      type Binary_Access is access all Binary_Array;

      function To_Array is new Unchecked_Conversion (Pointer, Binary_Access);

      Len : aliased C.unsigned;
      Id  : Binary_Access;

   begin
      if Session = null then
         return "";
      end if;

      Id := To_Array (SSL_SESSION_get_id (SSL_Session (Session), Len'Access));

      return Translator.Base64_Encode (Id (1 .. Stream_Element_Offset (Len)));
   end Session_Id_Image;

   function Session_Id_Image (Socket : Socket_Type) return String is
   begin
      return Session_Id_Image
        (Session_Type (TSSL.SSL_get_session (Socket.SSL)));
   end Session_Id_Image;

   --------------------
   -- Session_Reused --
   --------------------

   function Session_Reused (Socket : Socket_Type) return Boolean is
      use TSSL;
      Rc : constant C.int := SSL_session_reused (Socket.SSL);
   begin
      if Rc = 0 then
         return False;
      end if;

      Error_If (Socket, Rc /= 1);

      return True;
   end Session_Reused;

   ----------------------
   -- Set_Accept_State --
   ----------------------

   procedure Set_Accept_State (Socket : Socket_Type) is
   begin
      Socket.Config.Check_CRL;
      TSSL.SSL_set_accept_state (Socket.SSL);

      if RSA_Params (0) = TSSL.Null_Pointer
        and then DH_Params (0) = TSSL.Null_Pointer
      then
         if not RSA_Lock.Locked and then not DH_Lock.Locked then
            Start_Parameters_Generation (DH => True);
         end if;

      else
         if RSA_Params (0) /= TSSL.Null_Pointer then
            TSSL.SSL_set_tmp_rsa_callback
              (SSL => Socket.SSL, RSA_CB => Tmp_RSA_Callback'Access);
         end if;

         if DH_Params (0) /= TSSL.Null_Pointer then
            TSSL.SSL_set_tmp_dh_callback
              (SSL => Socket.SSL, DH_CB => Tmp_DH_Callback'Access);
         end if;
      end if;
   end Set_Accept_State;

   ----------------
   -- Set_Config --
   ----------------

   procedure Set_Config
     (Socket : in out Socket_Type; Config : SSL.Config) is
   begin
      Socket.Config := Config;
   end Set_Config;

   -----------------------
   -- Set_Connect_State --
   -----------------------

   procedure Set_Connect_State (Socket : Socket_Type; Host : String) is
   begin
      TSSL.SSL_set_connect_state (Socket.SSL);

      if Host /= "" then
         Error_If
           (TSSL.SSL_set_tlsext_host_name (Socket.SSL, C.To_C (Host)) = 0);
      end if;
   end Set_Connect_State;

   ---------------
   -- Set_Debug --
   ---------------

   procedure Set_Debug
     (Level : Natural; Output : Debug_Output_Procedure := null) is
   begin
      Debug_Level  := Level;
      Debug_Output := Output;
   end Set_Debug;

   ----------------------------
   -- Set_Session_Cache_Size --
   ----------------------------

   procedure Set_Session_Cache_Size
     (Size : Natural; Config : SSL.Config := Null_Config) is
   begin
      if Config = Null_Config then
         Default_Client_Config.Set_Session_Cache_Size (Size);
         Default_Server_Config.Set_Session_Cache_Size (Size);
      else
         Config.Set_Session_Cache_Size (Size);
      end if;
   end Set_Session_Cache_Size;

   ----------------------------
   -- Set_Session_Cache_Size --
   ----------------------------

   procedure Set_Session_Cache_Size
     (Context : TSSL.SSL_CTX; Size : Integer) is
   begin
      case TSSL.SSL_CTX_set_session_cache_mode
        (Ctx  => Context,
         Mode => (if Size = 0 then TSSL.SSL_SESS_CACHE_OFF
                  else TSSL.SSL_SESS_CACHE_SERVER))
      is
         when TSSL.SSL_SESS_CACHE_OFF | TSSL.SSL_SESS_CACHE_SERVER => null;
         when others =>
            raise Socket_Error with "Unexpected session cache mode";
      end case;

      Error_If
        (TSSL.SSL_CTX_ctrl
           (Ctx  => Context,
            Cmd  => TSSL.SSL_CTRL_SET_SESS_CACHE_SIZE,
            Larg => C.long (Size),
            Parg => TSSL.Null_Pointer) = -1);
   end Set_Session_Cache_Size;

   ----------------------
   -- Set_Session_Data --
   ----------------------

   procedure Set_Session_Data
     (Socket : in out Socket_Type; Data : Session_Type) is
   begin
      if Socket.SSL = TSSL.Null_Handle or else Socket.Get_FD = No_Socket then
         Socket.Sessn := Data;
      else
         Error_If
           (Socket,
            TSSL.SSL_set_session (Socket.SSL, TSSL.SSL_Session (Data)) = 0);
      end if;
   end Set_Session_Data;

   -------------------------
   -- Set_Verify_Callback --
   -------------------------

   procedure Set_Verify_Callback
     (Config : in out SSL.Config; Callback : System.Address) is
   begin
      Config.Set_Verify_Callback (Callback);
   end Set_Verify_Callback;

   -----------------------------
   -- Show_Session_Statistic --
   -----------------------------

   procedure Show_Session_Statistic
     (Config : SSL.Config;
      Report : not null access procedure (Line : String))
   is
      use TSSL;

      Ctx : constant SSL_CTX := Config.Get_Context;

      procedure Output (Title : String; Cmd : C.int);

      ------------
      -- Output --
      ------------

      procedure Output (Title : String; Cmd : C.int) is
      begin
         Report (Title & TSSL.SSL_CTX_ctrl (Ctx, Cmd, 0, Null_Pointer)'Img);
      end Output;

   begin
      Output ("cache_size         ", SSL_CTRL_GET_SESS_CACHE_SIZE);
      Output ("number             ", SSL_CTRL_SESS_NUMBER);
      Output ("connect            ", SSL_CTRL_SESS_CONNECT);
      Output ("connect_good       ", SSL_CTRL_SESS_CONNECT_GOOD);
      Output ("connect_renegotiate", SSL_CTRL_SESS_CONNECT_RENEGOTIATE);
      Output ("accept             ", SSL_CTRL_SESS_ACCEPT);
      Output ("accept_good        ", SSL_CTRL_SESS_ACCEPT_GOOD);
      Output ("accept_renegotiate ", SSL_CTRL_SESS_ACCEPT_RENEGOTIATE);
      Output ("hits               ", SSL_CTRL_SESS_HIT);
      Output ("cb_hits            ", SSL_CTRL_SESS_CB_HIT);
      Output ("misses             ", SSL_CTRL_SESS_MISSES);
      Output ("timeouts           ", SSL_CTRL_SESS_TIMEOUTS);
      Output ("cache_full         ", SSL_CTRL_SESS_CACHE_FULL);
   end Show_Session_Statistic;

   --------------
   -- Shutdown --
   --------------

   overriding procedure Shutdown
     (Socket : Socket_Type; How : Shutmode_Type := Shut_Read_Write)
   is
      RC   : C.int;
      Both : Boolean := False;

      function Error_Processing return Boolean;
      --  Exit from shutdown loop on True result

      ----------------------
      -- Error_Processing --
      ----------------------

      function Error_Processing return Boolean is
         Error_Code : constant C.int := TSSL.SSL_get_error (Socket.SSL, RC);
         Err_Code   : TSSL.Error_Code;
         RIO        : TSSL.BIO_Access;
         BIO        : TSSL.BIO_Access;
         Retry      : aliased C.int;

         use type TSSL.Error_Code, TSSL.BIO_Access;

      begin
         case Error_Code is
            when TSSL.SSL_ERROR_WANT_READ =>
               if Net.Socket_Type (Socket).Timeout > Shutdown_Read_Timeout then
                  Socket_Write (Socket);
                  Wait_For (Input, NSST (Socket), Shutdown_Read_Timeout);
               end if;

               Socket_Read (Socket);

            when TSSL.SSL_ERROR_WANT_WRITE =>
               Socket_Write (Socket);

            when TSSL.SSL_ERROR_SYSCALL =>
               RIO := TSSL.BIO_get_retry_BIO (Socket.IO, Retry'Access);
               BIO := TSSL.SSL_get_rbio (Socket.SSL);
               Err_Code := TSSL.ERR_get_error;

               if Err_Code /= 0
                 or else TSSL.SSL_want (Socket.SSL) /= TSSL.SSL_NOTHING
                 or else Retry /= 0
                 or else Socket.IO.Flags /= 0
                 or else RIO.Flags /= 0
                 or else BIO.Flags /= 0
                 or else Socket.Pending /= 0
               then
                  Net.Log.Error
                    (Socket,
                     "Unexpected SSL_ERROR_SYSCALL "
                     & Boolean'Image (RIO = Socket.IO)
                     & ' ' & Boolean'Image (BIO = Socket.IO)
                     & Err_Code'Img
                     & TSSL.SSL_want (Socket.SSL)'Img
                     & Retry'Img
                     & Socket.IO.Flags'Img
                     & RIO.Flags'Img
                     & BIO.Flags'Img
                     & Socket.Pending'Img
                     & Std.Pending (NSST (Socket))'Img);

                  return True;
               end if;

            when others =>
               Err_Code := TSSL.ERR_get_error;

               if Err_Code = 0 then
                  Net.Log.Error
                    (Socket,
                     "Error (" & Utils.Image (Integer (Error_Code))
                     & ") on SSL shutdown");
               else
                  Net.Log.Error (Socket, Error_Str (Err_Code));
               end if;

               return True;
         end case;

         return False;

      exception
         when Socket_Error =>
            return True;
      end Error_Processing;

   begin
      if Socket.SSL /= TSSL.Null_Handle then
         loop
            RC := TSSL.SSL_shutdown (Socket.SSL);

            exit when RC > 0;

            if RC = 0 then
               --  First part of bidirectional shutdown done

               if How = Shut_Write then
                  exit;
               end if;

               if Both then
                  exit when Error_Processing;
               else
                  Both := True;
               end if;

            else
               exit when Error_Processing;
            end if;
         end loop;
      end if;

      Net.Std.Shutdown (NSST (Socket), How);
   end Shutdown;

   ---------------
   -- Signature --
   ---------------

   function Signature
     (Ptr  : System.Address;
      Size : C.size_t;
      Key  : Private_Key;
      Hash : Hash_Method) return Stream_Element_Array
   is
      use TSSL;
      use type C.unsigned, C.size_t;

      To_EVP_MD : constant array (Hash_Method) of EVP_MD :=
                    [MD5    => EVP_md5,
                     SHA1   => EVP_sha1,
                     SHA224 => EVP_sha224,
                     SHA256 => EVP_sha256,
                     SHA384 => EVP_sha384,
                     SHA512 => EVP_sha512];

      Md     : constant EVP_MD := To_EVP_MD (Hash);
      D_Ctx  : constant EVP_MD_CTX := EVP_MD_CTX_new;
      Dig    : Stream_Element_Array
                 (1 .. Stream_Element_Offset (EVP_MD_size (Md)));
      D_Size : aliased C.unsigned := Dig'Length;

      S_Ctx  : EVP_PKEY_CTX;
      Res    : Stream_Element_Array
                 (1 .. Stream_Element_Offset (EVP_PKEY_size (Key)));
      S_Size : aliased C.size_t := Res'Length;
   begin
      Error_If (EVP_DigestInit (D_Ctx, Md) = 0);
      Error_If (EVP_DigestUpdate (D_Ctx, Ptr, Size) = 0);
      Error_If (EVP_DigestFinal (D_Ctx, Dig'Address, D_Size'Access) = 0);
      EVP_MD_CTX_free (D_Ctx);

      if D_Size /= Dig'Length then
         raise Program_Error with "Digest length error";
      end if;

      S_Ctx := SSL.EVP_PKEY_CTX_new (Key, ENGINE (Null_Pointer));
      Error_If (S_Ctx = EVP_PKEY_CTX (Null_Pointer));
      Error_If (EVP_PKEY_sign_init (S_Ctx) <= 0);
      Error_If (EVP_PKEY_CTX_set_signature_md (S_Ctx, To_EVP_MD (Hash)) <= 0);
      Error_If
        (EVP_PKEY_sign
           (S_Ctx, Res'Address, S_Size'Access, Dig'Address, Dig'Length) <= 0);
      EVP_PKEY_CTX_free (S_Ctx);

      if S_Size > Res'Length then
         raise Program_Error with
           "Signature length error " & S_Size'Img & Res'Length'Img;
      end if;

      return Res (1 .. Stream_Element_Offset (S_Size));
   end Signature;

   -----------------
   -- Socket_Pair --
   -----------------

   overriding procedure Socket_Pair (S1, S2 : out Socket_Type) is
      ST1, ST2 : Std.Socket_Type;
   begin
      Std.Socket_Pair (ST1, ST2);
      S1 := Secure_Server (ST1);
      S2 := Secure_Client (ST2);
   end Socket_Pair;

   -----------------
   -- Socket_Read --
   -----------------

   procedure Socket_Read (Socket : Socket_Type) is
      use TSSL;

      Data : aliased Memory_Access;
      Len  : Stream_Element_Offset;
      Last : Stream_Element_Offset;
   begin
      Socket_Write (Socket);

      Len := Stream_Element_Offset (BIO_nwrite0 (Socket.IO, Data'Address));

      Net.Std.Receive (NSST (Socket), Data (1 .. Len), Last);

      if TSSL.BIO_nwrite (Socket.IO, Data'Address, C.int (Last))
         /= C.int (Last)
      then
         raise Socket_Error with "Not enought memory.";
      end if;
   end Socket_Read;

   ------------------
   -- Socket_Write --
   ------------------

   procedure Socket_Write (Socket : Socket_Type; Gone : C.int := 0) is
      use TSSL;

      Data  : aliased Memory_Access;
      Cnt   : constant C.int := BIO_nread0 (Socket.IO, Data'Address);
      Cnt1  : C.int;
      Last  : Stream_Element_Offset;
      Plain : constant Net.Std.Socket_Type := NSST (Socket);
   begin
      if Cnt <= 0 then
         return;
      end if;

      if Gone > 0 and then Cnt - Gone > C.int (Max_Overhead) then
         --  Looks like Max_Overhead is not enought

         Max_Overhead := Stream_Element_Offset (Cnt - Gone);

         Log.Error
           (Socket,
            "Increase Max_Overhead to" & Max_Overhead'Img
            & " in the aws-net-ssl_openssl.adb to avoid send locking");
      end if;

      Plain.Send (Data (1 .. Stream_Element_Offset (Cnt)), Last);

      if Last < Stream_Element_Offset (Cnt) then
         if not Net.Socket_Type (Socket).C.Can_Wait then
            Log.Error (Socket, "Unexpected blocking send");
         end if;

         --  Most likely Max_Overhead value is not enought, send rest data
         --  locking.

         Plain.Send (Data (Last + 1 .. Stream_Element_Offset (Cnt)));
      end if;

      Cnt1 := BIO_nread (Socket.IO, Data'Address, Cnt);

      if Cnt1 /= Cnt then
         if SSL_get_shutdown (Socket.SSL) /= 0 then
            Log.Error (Socket, "Shutdown detected" & Cnt'Img & Cnt1'Img);
         else
            raise Program_Error with Cnt'Img & Cnt1'Img;
         end if;
      end if;
   end Socket_Write;

   Keep_M, Keep_R, Keep_F : System.Address;

   -------------
   -- Locking --
   -------------

   package body Locking is

      type Task_Identifier is new C.unsigned_long;
      type Lock_Index is new C.int;
      type Mode_Type is mod 2 ** C.int'Size;

      type Task_Data is record
         TID                      : Task_Identifier;
         Keep_Termination_Handler : Task_Termination.Termination_Handler;
      end record;

      subtype Filename_Type is C.Strings.chars_ptr;
      subtype Line_Number is C.int;

      Finalized : Boolean := False;
      --  Need to avoid access to finalized protected locking objects

      Keep_Termination_Handler : Task_Termination.Termination_Handler;
      --  To keep previous common task termination handler

      package Task_Identifiers is new Task_Attributes
        (Task_Data, (TID => 0, Keep_Termination_Handler => null));

      procedure Finalize;

      protected Task_Id_Generator is

         procedure Get_Task_Id (Id : out Task_Identifier) with
           Post => Id > 0;
         --  Return a uniq Id starting from 1 and incrementing one by one

         procedure Finalize_Task
           (Cause : Task_Termination.Cause_Of_Termination;
            T     : Task_Identification.Task_Id;
            X     : Exceptions.Exception_Occurrence);

      private
         Id_Counter : Task_Identifier := 0;
      end Task_Id_Generator;

      subtype RW_Mutex is AWS.Utils.RW_Semaphore (1);

      type RW_Mutex_Access is access all RW_Mutex;

      Locks : array (1 .. Lock_Index (TSSL.CRYPTO_num_locks)) of RW_Mutex;

      F : Utils.Finalizer (Finalize'Access) with Unreferenced;

      procedure Lock (Mode : Mode_Type; Locker : in out RW_Mutex) with Inline;

      procedure Locking_Function
        (Mode : Mode_Type;
         N    : Lock_Index;
         File : Filename_Type;
         Line : Line_Number)
        with Convention => C;

      function Dyn_Create
        (File : Filename_Type; Line : Line_Number) return RW_Mutex_Access
        with Convention => C;

      procedure Dyn_Lock
        (Mode   : Mode_Type;
         Locker : RW_Mutex_Access;
         File   : Filename_Type;
         Line   : Line_Number)
        with Convention => C;

      procedure Dyn_Destroy
        (Locker : RW_Mutex_Access;
         File   : Filename_Type;
         Line   : Line_Number)
        with Convention => C;

      function Get_Task_Identifier return Task_Identifier with Convention => C;

      ----------------
      -- Dyn_Create --
      ----------------

      function Dyn_Create
        (File : Filename_Type; Line : Line_Number) return RW_Mutex_Access
      is
         pragma Unreferenced (File, Line);
      begin
         return new RW_Mutex;
      end Dyn_Create;

      -----------------
      -- Dyn_Destroy --
      -----------------

      procedure Dyn_Destroy
        (Locker : RW_Mutex_Access;
         File   : Filename_Type;
         Line   : Line_Number)
      is
         pragma Unreferenced (File, Line);

         Temp : RW_Mutex_Access := Locker;

         procedure Free is
           new Unchecked_Deallocation (RW_Mutex, RW_Mutex_Access);
      begin
         Free (Temp);
      end Dyn_Destroy;

      --------------
      -- Dyn_Lock --
      --------------

      procedure Dyn_Lock
        (Mode   : Mode_Type;
         Locker : RW_Mutex_Access;
         File   : Filename_Type;
         Line   : Line_Number)
      is
         pragma Unreferenced (File, Line);
      begin
         Lock (Mode, Locker.all);
      end Dyn_Lock;

      --------------
      -- Finalize --
      --------------

      procedure Finalize is
      begin
         for J in DH_Params'Range loop
            if DH_Params (J) /= TSSL.Null_Pointer then
               TSSL.DH_free (DH_Params (J));
               DH_Params (J) := TSSL.Null_Pointer;
            end if;
         end loop;

         if Keep_M /= System.Null_Address
           and then TSSL.CRYPTO_set_mem_functions (Keep_M, Keep_R, Keep_F) = 0
         then
            Keep_M := System.Null_Address;
         end if;

         Finalized := True;
      end Finalize;

      -------------------------
      -- Get_Task_Identifier --
      -------------------------

      function Get_Task_Identifier return Task_Identifier is
         TA : constant Task_Identifiers.Attribute_Handle :=
                Task_Identifiers.Reference;
         CT : Task_Identification.Task_Id;
      begin
         if TA.TID = 0 then
            Task_Id_Generator.Get_Task_Id (TA.TID);

            CT := Task_Identification.Current_Task;

            TA.Keep_Termination_Handler :=
              Task_Termination.Specific_Handler (CT);

            Task_Termination.Set_Specific_Handler
              (CT, Task_Id_Generator.Finalize_Task'Access);
         end if;

         return TA.TID;
      end Get_Task_Identifier;

      ----------------
      -- Initialize --
      ----------------

      procedure Initialize is
      begin
         if TSSL.OpenSSL_version_num < 16#10101000# then
            --  We do not have to install thread id_callback on MS Windows and
            --  on platforms where getpid returns different id for each thread.
            --  But it is easier to install it for all platforms.

            TSSL.CRYPTO_set_id_callback (Get_Task_Identifier'Address);
            TSSL.CRYPTO_set_locking_callback (Locking_Function'Address);

            TSSL.CRYPTO_set_dynlock_create_callback  (Dyn_Create'Address);
            TSSL.CRYPTO_set_dynlock_lock_callback    (Dyn_Lock'Address);
            TSSL.CRYPTO_set_dynlock_destroy_callback (Dyn_Destroy'Address);

         else
            --  Do not need any special locking callbacks since OpenSSL version
            --  1.1.1, but we need to finalize all tasks because of another
            --  reason.
            --  OpenSSL finalizes all threads automatically including in GNAT
            --  tasks, but too late, when GNAT already deallocated task control
            --  block. We have overriden memory allocation routines with
            --  CRYPTO_set_mem_functions in this package initialization. And
            --  when OpenSSL deallocates thread specific memory on GNAT task
            --  without control block, the new control block automatically
            --  allocated again and we've got memory leak at task termination.
            --  If we deallocate OpenSSL thread specific memore before
            --  deallocation of the GNAT task control block we avoid
            --  deallocation after the control block gone.

            Keep_Termination_Handler :=
              Task_Termination.Current_Task_Fallback_Handler;

            Task_Termination.Set_Dependents_Fallback_Handler
              (Locking.Task_Id_Generator.Finalize_Task'Access);
         end if;
      end Initialize;

      ----------
      -- Lock --
      ----------

      procedure Lock (Mode : Mode_Type; Locker : in out RW_Mutex) is
      begin
         if Finalized then
            return;
         end if;

         case Mode is
            when TSSL.CRYPTO_LOCK   or TSSL.CRYPTO_WRITE =>
               Locker.Write;
            when TSSL.CRYPTO_LOCK   or TSSL.CRYPTO_READ  =>
               Locker.Read;
            when TSSL.CRYPTO_UNLOCK or TSSL.CRYPTO_WRITE =>
               Locker.Release_Write;
            when TSSL.CRYPTO_UNLOCK or TSSL.CRYPTO_READ  =>
               Locker.Release_Read;
            when others => null;
         end case;
      end Lock;

      ----------------------
      -- Locking_Function --
      ----------------------

      procedure Locking_Function
        (Mode : Mode_Type;
         N    : Lock_Index;
         File : Filename_Type;
         Line : Line_Number)
      is
         pragma Unreferenced (File, Line);
      begin
         Lock (Mode, Locks (N));
      end Locking_Function;

      -----------------------
      -- Task_Id_Generator --
      -----------------------

      protected body Task_Id_Generator is

         -------------------
         -- Finalize_Task --
         -------------------

         procedure Finalize_Task
           (Cause : Task_Termination.Cause_Of_Termination;
            T     : Task_Identification.Task_Id;
            X     : Exceptions.Exception_Occurrence)
         is
            use type Task_Termination.Termination_Handler;
            TA : Task_Identifiers.Attribute_Handle;
         begin
            if TSSL.OpenSSL_version_num < 16#10101000# then
               --  It is task specific termination handler for OpenSSL 1.0 and
               --  older for locking support.

               TA := Task_Identifiers.Reference (T);

               TSSL.ERR_remove_state (C.int (TA.TID));

               if TA.Keep_Termination_Handler /= null then
                  TA.Keep_Termination_Handler (Cause, T, X);
               end if;

            else
               --  It is common task termination handler for OpenSSL 1.1 and
               --  newer to avoid memory leak on overriden by
               --  CRYPTO_set_mem_functions memory allocation routines.

               TSSL.OPENSSL_thread_stop;

               if Keep_Termination_Handler /= null then
                  Keep_Termination_Handler (Cause, T, X);
               end if;
            end if;
         end Finalize_Task;

         -----------------
         -- Get_Task_Id --
         -----------------

         procedure Get_Task_Id (Id : out Task_Identifier) is
         begin
            Id_Counter := @ + 1;
            Id := Id_Counter;
         end Get_Task_Id;

      end Task_Id_Generator;

   end Locking;


   ---------------------------------
   -- Start_Parameters_Generation --
   ---------------------------------

   procedure Start_Parameters_Generation
     (DH : Boolean; Logging : access procedure (Text : String) := null) is
   begin
      RSA_DH_Generators.Start_Parameters_Generation (DH, Logging);
   end Start_Parameters_Generation;

   ---------------------
   -- Tmp_DH_Callback --
   ---------------------

   function Tmp_DH_Callback
     (SSL : SSL_Handle; Is_Export : C.int; Keylength : C.int) return TSSL.DH
   is
      pragma Unreferenced (SSL, Is_Export, Keylength);
      --  Ignore export restrictions
   begin
      return DH_Params (0);
   end Tmp_DH_Callback;

   ----------------------
   -- Tmp_RSA_Callback --
   ----------------------

   function Tmp_RSA_Callback
     (SSL : SSL_Handle; Is_Export : C.int; Keylength : C.int) return TSSL.RSA
   is
      pragma Unreferenced (SSL, Is_Export, Keylength);
      --  Ignore export restrictions
   begin
      return RSA_Params (0);
   end Tmp_RSA_Callback;

   -------------------
   -- To_Char_Array --
   -------------------

   function To_Char_Array (Protocols : SV.Vector) return C.char_array is
      use type C.size_t;
      Idx : C.size_t := 0;
   begin
      --  Calculate length of the result into Idx

      for P of Protocols loop
         Idx := @ + P'Length + 1;
      end loop;

      declare
         Protos : C.char_array (1 .. Idx);
      begin
         --  Fill the result into Protos

         Idx := Protos'First;

         for P of Protocols loop
            Protos (Idx .. Idx + P'Length) := To_Char_Array (P);
            Idx := @ + P'Length + 1;
         end loop;

         return Protos;
      end;
   end To_Char_Array;

   ------------
   -- TS_SSL --
   ------------

   protected body TS_SSL is

      ------------------
      -- ALPN_Include --
      ------------------

      procedure ALPN_Include (Protocol : String) is
         use type C.size_t, C.char_array;

         Ref : C.Strings.char_array_access;
         Idx : C.size_t;
         Len : C.size_t;
         CA  : constant C.char_array := To_Char_Array (Protocol);
      begin
         if ALPN.Is_Empty then
            ALPN_Set (CA);
            return;
         end if;

         Ref := ALPN.Reference.Element;

         Idx := Ref'First;

         loop
            Len := C.char'Pos (Ref (Idx));
            if Ref (Idx .. Idx + Len) = CA then
               --  Already there
               return;
            end if;

            Idx := @ + Len + 1;
            exit when Idx > Ref'Last;
         end loop;

         pragma Assert (Idx = Ref'Last + 1);

         ALPN_Set (Ref.all & CA);
      end ALPN_Include;

      --------------
      -- ALPN_Set --
      --------------

      procedure ALPN_Set (Protos : C.char_array) is
      begin
         Error_If
           (TSSL.SSL_CTX_set_alpn_protos
              (Default_Context, Protos, Protos'Length) /= 0);
         ALPN.Replace_Element (Protos);
         if Protos'Length > 0 then
            TSSL.SSL_CTX_set_alpn_select_cb
              (Default_Context, ALPN_Callback'Access, ALPN'Address);
         end if;
      end ALPN_Set;

      ---------------
      -- Check_CRL --
      ---------------

      procedure Check_CRL is
         use type Ada.Calendar.Time;
         use type C.Strings.chars_ptr;

         procedure Reload_CRL_File (Context : TSSL.SSL_CTX);

         ---------------------
         -- Reload_CRL_File --
         ---------------------

         procedure Reload_CRL_File (Context : TSSL.SSL_CTX) is
            Store  : constant TSSL.X509_STORE :=
              TSSL.SSL_CTX_get_cert_store (Context);
            Lookup : constant TSSL.X509_LOOKUP :=
              TSSL.X509_STORE_add_lookup
                (Store, TSSL.X509_LOOKUP_file);
            Param  : constant TSSL.X509_VERIFY_PARAM :=
              TSSL.X509_VERIFY_PARAM_new;
         begin
            --  Load CRL

            Error_If
              (TSSL.X509_load_crl_file
                 (Lookup, CRL_Filename, TSSL.X509_FILETYPE_PEM) /= 1);

            --  Set up certificate store to check CRL

            Error_If
              (TSSL.X509_VERIFY_PARAM_set_flags
                 (Param, TSSL.X509_V_FLAG_CRL_CHECK) < 0);
            Error_If (TSSL.X509_STORE_set1_param (Store, Param) < 0);
            TSSL.X509_VERIFY_PARAM_free (Param);
         end Reload_CRL_File;

      begin
         --  We need to load the CRL file if CRL_Time_Stamp is AWS_Epoch (it
         --  has never been loaded) or the time stamp has changed on disk.

         if CRL_Filename /= C.Strings.Null_Ptr then
            declare
               TS : constant Calendar.Time :=
                      Utils.File_Time_Stamp (C.Strings.Value (CRL_Filename));
            begin
               if CRL_Time_Stamp = Utils.AWS_Epoch
                 or else CRL_Time_Stamp /= TS
               then
                  CRL_Time_Stamp := TS;
                  Reload_CRL_File (Default_Context);
                  for Context of Hosts loop
                     Reload_CRL_File (Context);
                  end loop;
               end if;
            end;
         end if;
      end Check_CRL;

      -------------------------
      -- Clear_Session_Cache --
      -------------------------

      procedure Clear_Session_Cache is
      begin
         TSSL.SSL_CTX_flush_sessions (Default_Context, C.long'Last);
         for Context of Hosts loop
            TSSL.SSL_CTX_flush_sessions (Context, C.long'Last);
         end loop;
      end Clear_Session_Cache;

      -----------------------------
      -- Common_Certificate_Init --
      -----------------------------

      procedure Common_Certificate_Init (Context : out TSSL.SSL_CTX) is

         use Interfaces.C;

         Methods : constant array (Method) of Meth_Func :=
                     [TLS            => TSSL.TLS_method'Access,
                      TLS_Server     => TSSL.TLS_server_method'Access,
                      TLS_Client     => TSSL.TLS_client_method'Access,
                      TLSv1          => TSSL.TLSv1_method'Access,
                      TLSv1_Server   => TSSL.TLSv1_server_method'Access,
                      TLSv1_Client   => TSSL.TLSv1_client_method'Access,
                      TLSv1_1        => TSSL.TLSv1_1_method'Access,
                      TLSv1_1_Server => TSSL.TLSv1_1_server_method'Access,
                      TLSv1_1_Client => TSSL.TLSv1_1_client_method'Access,
                      TLSv1_2        => TSSL.TLSv1_2_method'Access,
                      TLSv1_2_Server => TSSL.TLSv1_2_server_method'Access,
                      TLSv1_2_Client => TSSL.TLSv1_2_client_method'Access];

      begin
         --  Initialize context

         Context := TSSL.SSL_CTX_new (Methods (Security_Mode).all);

         Error_If (Context = TSSL.Null_CTX);

         if not Ticket_Support then
            Error_If
              (TSSL.SSL_CTX_set_options (Context, TSSL.SSL_OP_NO_TICKET) = 0);
         end if;

         Error_If
           (TSSL.SSL_CTX_ctrl
              (Ctx  => Context,
               Cmd  => TSSL.SSL_CTRL_MODE,
               Larg => TSSL.SSL_MODE_ENABLE_PARTIAL_WRITE
                       + TSSL.SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER,
               Parg => TSSL.Null_Pointer) = 0);
      end Common_Certificate_Init;

      ----------------
      -- File_Error --
      ----------------

      procedure File_Error (Prefix, Name : String) is
      begin
         raise Socket_Error
           with Prefix & " file """ & Name & """ error." & ASCII.LF
           & Error_Stack;
      end File_Error;

      --------------
      -- Finalize --
      --------------

      procedure Finalize is
      begin
         TSSL.SSL_CTX_free (Default_Context);
         Default_Context := TSSL.Null_CTX;

         for Context of Hosts loop
            TSSL.SSL_CTX_free (Context);
         end loop;
         Hosts.Clear;

         C.Strings.Free (Trusted_CA_Filename);
         C.Strings.Free (CRL_Filename);
         C.Strings.Free (Priorities);
         C.Strings.Free (Prio_TLS13);
      end Finalize;

      ---------------------------
      -- Get_Check_Certificate --
      ---------------------------

      function Get_Check_Certificate return Boolean is
      begin
         return Check_Certificate;
      end Get_Check_Certificate;

      -----------------
      -- Get_Context --
      -----------------

      function Get_Context return TSSL.SSL_CTX is
      begin
         return Default_Context;
      end Get_Context;

      function Get_Handshake_Timeout return Duration is
      begin
         return Handshake_Timeout;
      end Get_Handshake_Timeout;

      ----------------
      -- Initialize --
      ----------------

      procedure Initialize
        (Security_Mode         : Method;
         Server_Certificate    : String;
         Server_Key            : String;
         Client_Certificate    : String;
         Priorities            : String;
         Ticket_Support        : Boolean;
         Exchange_Certificate  : Boolean;
         Check_Certificate     : Boolean;
         Trusted_CA_Filename   : String;
         CRL_Filename          : String;
         Session_Cache_Size    : Natural;
         ALPN                  : C.char_array;
         SSL_Handshake_Timeout : Duration) is
      begin
         Prepare
           (Security_Mode, Priorities, Ticket_Support, Exchange_Certificate,
            Check_Certificate,
            Trusted_CA_Filename, CRL_Filename,
            Session_Cache_Size);

         if Security_Mode = Net.SSL.TLS_Client then
            Initialize_Client_Certificate
              ("", Client_Certificate);
         else
            Initialize_Host_Certificate
              ("", Server_Certificate, Server_Key);
         end if;
         Handshake_Timeout := SSL_Handshake_Timeout;
         if ALPN'Length > 0 then
            ALPN_Set (ALPN);
         end if;
      end Initialize;

      -----------------------------------
      -- Initialize_Client_Certificate --
      -----------------------------------

      procedure Initialize_Client_Certificate
        (Host                 : String;
         Certificate_Filename : String)
      is
         use C.Strings;
         use Interfaces.C;

         Context : TSSL.SSL_CTX;
         Dummy   : C.long;

      begin
         if Default_Context /= TSSL.Null_CTX and then Host = "" then
            return;
         end if;

         Common_Certificate_Init (Context);

         if Exchange_Certificate then
            Error_If
              (TSSL.SSL_CTX_set_ex_data
                 (Context, Data_Index, TSSL.Null_Pointer) = 0);
         end if;

         if Check_Certificate then
            declare
               Mode : constant C.int := TSSL.SSL_VERIFY_PEER;
            begin
               TSSL.SSL_CTX_set_verify
                 (Context, Mode, Verify_Callback'Address);
            end;
         end if;

         if Certificate_Filename /= "" then
            declare
               PK : constant Private_Key :=
                      Load (Certificate_Filename);
            begin
               if TSSL.SSL_CTX_use_certificate_chain_file
                 (Ctx => Context, File => To_C (Certificate_Filename)) /= 1
               then
                  File_Error ("Certificate", Certificate_Filename);
               end if;

               Error_If
                (TSSL.SSL_CTX_use_PrivateKey
                   (Context, TSSL.EVP_PKEY (PK)) /= 1);

               if Exchange_Certificate then
                  declare
                     Data : aliased constant Stream_Element_Array :=
                              Signature (Command_Line.Command_Name,
                                         PK, SHA224);
                  begin
                     Error_If
                       (TSSL.SSL_CTX_set_session_id_context
                          (Context, Data'Address,
                           C.unsigned'Min
                             (TSSL.SSL_MAX_SSL_SESSION_ID_LENGTH,
                              Data'Length)) = 0);
                  end;
               end if;
            end;
         end if;

         Set_Trusted_CA_Certificate (Context);

         if Prio_TLS13 /= Null_Ptr
           and then TSSL.SSL_CTX_set_ciphersuites (Context, Prio_TLS13) = 0
         then
            Log_Error (Error_Stack);
            --  Do not try to set Prio_TLS13 with errors again
            Free (Prio_TLS13);
         end if;

         if Priorities /= Null_Ptr
           and then TSSL.SSL_CTX_set_cipher_list (Context, Priorities) = 0
         then
            Log_Error (Error_Stack);
            --  Do not try to set priorities with errors again
            Free (Priorities);
         end if;

         Set_Session_Cache_Size (Context, Session_Cache_Size);

         if Host = "" then
            Default_Context := Context;
         else
            Hosts.Insert (Host, Context);
         end if;

         if Certificate_Filename /= "" then
            Check_CRL;
         end if;
      end Initialize_Client_Certificate;

      ---------------------------------
      -- Initialize_Host_Certificate --
      ---------------------------------

      procedure Initialize_Host_Certificate
        (Host                 : String;
         Certificate_Filename : String;
         Key_Filename         : String)
      is
         use C.Strings;
         use Interfaces.C;

         procedure Set_Certificate;

         Context : TSSL.SSL_CTX;
         Dummy   : C.long;

         ---------------------
         -- Set_Certificate --
         ---------------------

         procedure Set_Certificate is
            PK : constant Private_Key :=
                   Load ((if Key_Filename = ""
                          then Certificate_Filename else Key_Filename));

         begin
            --  Get the single certificate or certificate chain from
            --  the file Cert_Filename.

            if TSSL.SSL_CTX_use_certificate_chain_file
              (Ctx => Context, File => To_C (Certificate_Filename)) /= 1
            then
               File_Error ("Certificate", Certificate_Filename);
            end if;

            Error_If
              (TSSL.SSL_CTX_use_PrivateKey (Context, TSSL.EVP_PKEY (PK)) /= 1);
            Error_If (TSSL.SSL_CTX_check_private_key (Ctx => Context) /= 1);

            if Exchange_Certificate then
               declare
                  Data : aliased constant Stream_Element_Array :=
                           Signature (Command_Line.Command_Name, PK, SHA224);
               begin
                  Error_If
                    (TSSL.SSL_CTX_set_session_id_context
                       (Context, Data'Address,
                        C.unsigned'Min
                          (TSSL.SSL_MAX_SSL_SESSION_ID_LENGTH, Data'Length))
                     = 0);
               end;
            end if;

            --  Set Trusted Certificate Authority if any

            Set_Trusted_CA_Certificate (Context);
         end Set_Certificate;

      begin
         if Default_Context /= TSSL.Null_CTX and then Host = "" then
            return;
         end if;

         --  Initialize context

         Common_Certificate_Init (Context);

         if Exchange_Certificate then
            --  Client is requested to send its certificate once

            Error_If
              (TSSL.SSL_CTX_set_ex_data
                 (Context, Data_Index, TSSL.Null_Pointer) = 0);

            declare
               Mode : C.int :=
                 TSSL.SSL_VERIFY_PEER + TSSL.SSL_VERIFY_CLIENT_ONCE;
            begin
               if Check_Certificate then
                  Mode := @ + TSSL.SSL_VERIFY_FAIL_IF_NO_PEER_CERT;
               end if;

               TSSL.SSL_CTX_set_verify
                 (Context, Mode, Verify_Callback'Address);
            end;
         end if;

         if Certificate_Filename /= "" then
            Set_Certificate;
         end if;

         if Prio_TLS13 /= Null_Ptr
           and then TSSL.SSL_CTX_set_ciphersuites (Context, Prio_TLS13) = 0
         then
            Log_Error (Error_Stack);
            --  Do not try to set Prio_TLS13 with errors again
            Free (Prio_TLS13);
         end if;

         if Priorities /= Null_Ptr
           and then TSSL.SSL_CTX_set_cipher_list (Context, Priorities) = 0
         then
            Log_Error (Error_Stack);
            --  Do not try to set priorities with errors again
            Free (Priorities);
         end if;

         Set_Session_Cache_Size (Context, Session_Cache_Size);

         Dummy := TSSL.SSL_CTX_set_tlsext_servername_callback
                    (Context, Server_Name_Callback'Address);

         Dummy := TSSL.SSL_CTX_set_tlsext_servername_arg
                    (Context, Hosts'Address);

         if Host = "" then
            Default_Context := Context;
         else
            Hosts.Insert (Host, Context);
         end if;

         if Certificate_Filename /= "" then
            Check_CRL;
         end if;
      end Initialize_Host_Certificate;

      -------------
      -- New_SSL --
      -------------

      procedure New_SSL (Socket : in out Socket_Type) is
      begin
         Socket.SSL := TSSL.SSL_new (Default_Context);
         Error_If (Socket, Socket.SSL = TSSL.Null_Handle);
      end New_SSL;

      -------------
      -- Prepare --
      -------------

      procedure Prepare
        (Security_Mode        : Method;
         Priorities           : String;
         Ticket_Support       : Boolean;
         Exchange_Certificate : Boolean;
         Check_Certificate    : Boolean;
         Trusted_CA_Filename  : String;
         CRL_Filename         : String;
         Session_Cache_Size   : Natural)
      is
         use C.Strings;
         use GNAT.String_Split;

         TLS13 : constant String := "TLS13-";

         Prio_TLS13 : Unbounded_String :=
                           To_Unbounded_String
                             ("TLS_AES_256_GCM_SHA384"
                              & ":TLS_CHACHA20_POLY1305_SHA256"
                              & ":TLS_AES_128_GCM_SHA256");
         --  Will be C.Strings.Value (TSSL.OSSL_default_ciphersuites);
         --  in OpenSSL 3.0

         Prio_Slices : Slice_Set;
         Prio_Others : String (Priorities'First .. Priorities'Last + 1);
         Last_Others : Natural := Priorities'First - 1;

         Modified_TLS13 : Boolean := False;

         function Has_Cipher_TLS13 (Cipher : String) return Boolean;

         function New_C_String (Item : String) return chars_ptr is
           (if Item = "" then Null_Ptr else New_String (Item));

         procedure Append_TLS13_If_Absent (Cipher : String);

         procedure Remove_Cipher_TLS13 (Cipher : String);

         function Is_Substring
           (S : String; Sub : String; Shift : Natural) return Boolean
         is
           (S'Length >= Sub'Length + Shift
            and then S (S'First + Shift .. S'First + Shift + Sub'Length - 1) =
                     Sub);

         ----------------------------
         -- Append_TLS13_If_Absent --
         ----------------------------

         procedure Append_TLS13_If_Absent (Cipher : String) is
         begin
            if not Has_Cipher_TLS13 (Cipher) then
               if Prio_TLS13 = Null_Unbounded_String then
                  Prio_TLS13 := To_Unbounded_String (Cipher);
               else
                  Append (Prio_TLS13, ':');
                  Append (Prio_TLS13, Cipher);
               end if;

               Modified_TLS13 := True;
            end if;
         end Append_TLS13_If_Absent;

         ----------------------
         -- Has_Cipher_TLS13 --
         ----------------------

         function Has_Cipher_TLS13 (Cipher : String) return Boolean is
            Idx : constant Natural := Index (Prio_TLS13, Cipher);

            function Right_Start return Boolean is
              (Idx = 1 or else Element (Prio_TLS13, Idx - 1) = ':');

         begin
            if Idx = 0 then
               return False;

            elsif Idx < Length (Prio_TLS13) - Cipher'Length + 1 then
               --  Not last in the list

               return Element (Prio_TLS13, Idx + Cipher'Length) = ':'
                 and then Right_Start;
            end if;

            return Right_Start;
         end Has_Cipher_TLS13;

         -------------------------
         -- Remove_Cipher_TLS13 --
         -------------------------

         procedure Remove_Cipher_TLS13 (Cipher : String) is
            Idx : Natural;
         begin
            if Cipher = "" then
               Prio_TLS13     := Null_Unbounded_String;
               Modified_TLS13 := True;
               return;
            end if;

            Idx := Index (Prio_TLS13, Cipher);

            if Idx /= 0
              and then (Idx = 1 or else Element (Prio_TLS13, Idx - 1) = ':')
            then
               if Idx = Length (Prio_TLS13) - Cipher'Length + 1 then
                  if Idx = 1 then
                     Prio_TLS13 := Null_Unbounded_String;
                  else
                     Head (Prio_TLS13, Idx - 2);
                  end if;

                  Modified_TLS13 := True;

               elsif Element (Prio_TLS13, Idx + Cipher'Length) = ':' then
                  Replace_Slice (Prio_TLS13, Idx, Idx + Cipher'Length, "");
                  Modified_TLS13 := True;
               end if;
            end if;
         end Remove_Cipher_TLS13;

      begin
         Create (Prio_Slices, Priorities, ":");

         for S of Prio_Slices loop
            if Is_Substring (S, TLS13, 0) then
               Append_TLS13_If_Absent
                 (S (S'First + TLS13'Length .. S'Last));

            elsif Is_Substring (S, TLS13, 1) then
               declare
                  Cipher : constant String :=
                             S (S'First + TLS13'Length + 1 .. S'Last);
               begin
                  if S (S'First) in '!' | '-' | '+' then
                     Remove_Cipher_TLS13 (Cipher);

                     if S (S'First) = '+' then
                        Append_TLS13_If_Absent (Cipher);
                     end if;
                  end if;
               end;

            else
               Prio_Others (Last_Others + 1 .. Last_Others + S'Length) := S;
               Last_Others := Last_Others + S'Length + 1;
               Prio_Others (Last_Others) := ':';
            end if;
         end loop;

         if Prio_Others (Last_Others) = ':' then
            Last_Others := @ - 1;
         end if;

         TS_SSL.Security_Mode        := Security_Mode;
         TS_SSL.Ticket_Support       := Ticket_Support;
         TS_SSL.Exchange_Certificate := Exchange_Certificate;
         TS_SSL.Check_Certificate    := Check_Certificate;

         TS_SSL.Session_Cache_Size   := Session_Cache_Size;
         TS_SSL.CRL_Filename         := New_C_String (CRL_Filename);
         TS_SSL.Trusted_CA_Filename  :=
           (if Trusted_CA_Filename /= ""
              and then Directories.Exists (Trusted_CA_Filename)
            then New_C_String (Trusted_CA_Filename)
            else Null_Ptr);

         TS_SSL.Priorities           :=
           New_C_String (Prio_Others (Prio_Others'First .. Last_Others));

         if Modified_TLS13 then
            if Prio_TLS13 = Null_Unbounded_String then
               TS_SSL.Security_Mode :=
                 (case Security_Mode is
                     when TLS => TLSv1_2,
                     when TLS_Server => TLSv1_2_Server,
                     when TLS_Client => TLSv1_2_Client,
                     when others => Security_Mode);
            else
               TS_SSL.Prio_TLS13 := New_String (To_String (Prio_TLS13));
            end if;
         end if;
      end Prepare;

      --------------------------
      -- Session_Cache_Number --
      --------------------------

      function Session_Cache_Number return Natural is
         use TSSL;
      begin
         --  ??? Maybe summary ?
         return Natural
           (SSL_CTX_ctrl (Default_Context, SSL_CTRL_SESS_NUMBER, 0,
            Null_Pointer));
      end Session_Cache_Number;

      ------------
      -- Set_IO --
      ------------

      procedure Set_IO (Socket : in out Socket_Type) is
         use TSSL;
         Inside_IO, Net_IO : aliased BIO_Access;
      begin
         Error_If
           (BIO_new_bio_pair (Inside_IO'Access, 0, Net_IO'Access, 0) = 0);

         case Debug_Level is
            when 0 => null;
            when 1 => BIO_set_callback (Inside_IO, BIO_debug_callback'Access);
            when 2 => BIO_set_callback (Net_IO, BIO_debug_callback'Access);
            when others =>
               BIO_set_callback (Inside_IO, BIO_debug_callback'Access);
               BIO_set_callback (Net_IO, BIO_debug_callback'Access);
         end case;

         if Debug_Output /= null then
            if Debug_BIO_Output = null then
               Debug_BIO_Method        := TSSL.BIO_s_null;
               Debug_BIO_Method.Bwrite := BIO_Debug_Write'Address;
               Debug_BIO_Output        := TSSL.BIO_new (Debug_BIO_Method);
            end if;

            BIO_set_callback_arg (Inside_IO, Debug_BIO_Output);
            BIO_set_callback_arg (Net_IO,    Debug_BIO_Output);
         end if;

         Socket.IO := Net_IO;

         SSL_set_bio (Socket.SSL, Inside_IO, Inside_IO);
      end Set_IO;

      ----------------------------
      -- Set_Session_Cache_Size --
      ----------------------------

      procedure Set_Session_Cache_Size (Size : Natural) is
      begin
         Set_Session_Cache_Size (Default_Context, Size);
         for Context of Hosts loop
            Set_Session_Cache_Size (Context, Size);
         end loop;
      end Set_Session_Cache_Size;

      --------------------------------
      -- Set_Trusted_CA_Certificate --
      --------------------------------

      procedure Set_Trusted_CA_Certificate (Context : TSSL.SSL_CTX) is
         use type TSSL.STACK_OF_X509_NAME;
         use C.Strings;
      begin
         --  First load default Trusted Certificate Authority

         if Check_Certificate then
            TSSL.SSL_CTX_set_default_verify_paths (Context);
         end if;

         --  Set Trusted Certificate Authority if any

         if Trusted_CA_Filename /= Null_Ptr then
            Error_If
              (TSSL.SSL_CTX_load_verify_locations
                 (Context, Trusted_CA_Filename, Null_Ptr) /= 1);

            if Exchange_Certificate then
               --  Let server send to client CA authority names it trust

               if Trusted_CA_Stack = TSSL.Null_STACK_OF_X509_NAME then
                  Trusted_CA_Stack := TSSL.SSL_load_client_CA_file
                                        (Trusted_CA_Filename);
               else
                  Trusted_CA_Stack := TSSL.SSL_dup_CA_list
                                        (Trusted_CA_Stack);
               end if;

               TSSL.SSL_CTX_set_client_CA_list (Context, Trusted_CA_Stack);
            end if;
         end if;
      end Set_Trusted_CA_Certificate;

      -------------------------
      -- Set_Verify_Callback --
      -------------------------

      procedure Set_Verify_Callback (Callback : System.Address) is

         procedure Set_Callback (Context : TSSL.SSL_CTX);

         ------------------
         -- Set_Callback --
         ------------------

         procedure Set_Callback (Context : TSSL.SSL_CTX) is
         begin
            Error_If
              (TSSL.SSL_CTX_set_ex_data (Context, Data_Index, Callback) = 0);
         end Set_Callback;

      begin
         Set_Callback (Default_Context);

         for Context of Hosts loop
            Set_Callback (Context);
         end loop;
      end Set_Verify_Callback;

   end TS_SSL;

   ---------------------
   -- Verify_Callback --
   ---------------------

   function Verify_Callback
     (preverify_ok : C.int; ctx : TSSL.X509_STORE_CTX) return C.int
   is
      use type C.unsigned;
      use type Net.SSL.Certificate.Verify_Callback;

      function To_Callback is new Unchecked_Conversion
        (System.Address, Net.SSL.Certificate.Verify_Callback);

      CB      : aliased Net.SSL.Certificate.Verify_Callback;
      SSL     : SSL_Handle;
      SSL_CTX : TSSL.SSL_CTX;
      Cert    : TSSL.X509;
      Res     : C.int := preverify_ok;
      Mode    : C.unsigned;
      Status  : C.int;
   begin
      --  The SSL structure

      SSL := TSSL.X509_STORE_CTX_get_ex_data
        (ctx, TSSL.SSL_get_ex_data_X509_STORE_CTX_idx);

      --  The SSL context, this is the one we are looking for as it contains
      --  the register callback.

      SSL_CTX := TSSL.SSL_get_SSL_CTX (SSL);

      --  Get the current verification mode

      Mode := TSSL.SSL_get_verify_mode (SSL);

      --  Get the certificate as stored into the context

      Cert := TSSL.X509_STORE_CTX_get_current_cert (ctx);

      --  Get current error status, this will be stored into the certificate
      --  by the read routine below. It will be available in the user's verify
      --  callback if needed.

      Status := TSSL.X509_STORE_CTX_get_error (ctx);

      --  Get the user's callback stored at the Data_Index

      CB := To_Callback (TSSL.SSL_CTX_get_ex_data (SSL_CTX, Data_Index));

      if CB /= null then
         if CB (Net.SSL.Certificate.Impl.Read (Status, Cert)) then
            Res := 1;
         else
            Res := 0;
         end if;
      end if;

      --  If we did not ask to fail if no peer cert was received just
      --  unconditionally returns 1 (OK).

      if (Mode and TSSL.SSL_VERIFY_FAIL_IF_NO_PEER_CERT) = 0 then
         return 1;
      else
         return Res;
      end if;
   end Verify_Callback;

   -------------
   -- Version --
   -------------

   function Version (Build_Info : Boolean := False) return String is
      use TSSL;
      Result : constant String :=
                 C.Strings.Value (OpenSSL_version (OPENSSL_VERSION0));
   begin
      if Build_Info then
         return Result & ASCII.LF
           & C.Strings.Value (OpenSSL_version (OPENSSL_CFLAGS)) & ASCII.LF
           & C.Strings.Value (OpenSSL_version (OPENSSL_BUILT_ON)) & ASCII.LF
           & C.Strings.Value (OpenSSL_version (OPENSSL_PLATFORM)) & ASCII.LF
           & C.Strings.Value (OpenSSL_version (OPENSSL_DIR));
      else
         return Result;
      end if;
   end Version;

begin
   Initialize_Default_Config (TLS);

   TSSL.CRYPTO_get_mem_functions (M => Keep_M, R => Keep_R, F => Keep_F);

   --  Set the RTL memory allocation routines is necessary only to be able
   --  gnatmem to detect memory leaks allocated inside of OpenSSL library.
   --  If we do not use gnatmem memory allocation interceptor we don't need
   --  this interception and all GNAT tasks termination interception too by the
   --  way. See Locking.Initialize for OpenSSL 1.1.1 and newer comment.
   --  Would be good to have flag in System.Memory which defines is the gnatmem
   --  interceptors is in action.

   if TSSL.CRYPTO_set_mem_functions
        (M => System.Memory.Alloc'Address,
         R => Lib_Realloc'Address,
         F => System.Memory.Free'Address) = 0
   then
      --  In "OpenSSL FIPS Object Module" based on OpenSSL version 1.0.1e
      --  we are unable to setup our own memory allocation routines. GNATMEM
      --  would not be aware of memory allocations inside of OpenSSL in this
      --  case, but AWS is able to run anyway.

      Keep_M := System.Null_Address; -- To do not restore back
   end if;

   Locking.Initialize;

   if TSSL.SSL_library_init /= 0 then
      Init_Random;

      Data_Index :=
        TSSL.SSL_CTX_get_ex_new_index
          (0, TSSL.Null_Pointer, TSSL.Null_Pointer,
           TSSL.Null_Pointer, TSSL.Null_Pointer);
   else
      Data_Index := -1;
   end if;
end AWS.Net.SSL;
