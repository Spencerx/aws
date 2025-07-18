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

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Unicode;

with AWS.Response;
with AWS.Status;

with SOAP.Message.Payload;
with SOAP.Name_Space;
with SOAP.Types;
with SOAP.WSDL.Schema;

package SOAP.Utils is

   use Ada.Strings.Unbounded;

   function Tag (Name : String; Start : Boolean) return String;
   --  Returns XML tag named Name. If Start is True then an XML start element
   --  is returned otherwise an XML end element is returned.

   function Encode (Str : String) return String;
   --  Encode XML entities and return the resulting string
   procedure Encode (S : Unbounded_String; Result : in out Unbounded_String);
   --  Same as function, but append to Result

   function NS (Name : String) return String;
   --  Returns the namespace for Name, string prefix separated with a ':'

   function No_NS (Name : String) return String;
   --  Returns Name without leading name space if present

   function With_NS (NS, Name : String) return String;
   --  Returns NS:Name if NS is not empty otherwise just return Name

   function To_Name (Q_Name : String) return String;
   --  Returns a valid Ada name out of a fully qualified name

   function Is_Ada_Reserved_Word (Name : String) return Boolean;
   --  Returns True if Name is an Ada reserved word

   function Time_Instant
     (TI,
      Name      : String;
      Type_Name : String := Types.XML_Time_Instant)
      return Types.XSD_Time_Instant;
   --  Returns the timeInstant given an string encoded time

   function Date
     (Date,
      Name      : String;
      Type_Name : String := Types.XML_Date)
      return Types.XSD_Date;
   --  Returns the date given an string encoded date

   function Time
     (Time,
      Name      : String;
      Type_Name : String := Types.XML_Time)
      return Types.XSD_Time;
   --  Returns the time given an string encoded time

   function Duration
     (D, Name   : String;
      Type_Name : String := Types.XML_Duration)
      return Types.XSD_Duration
     with Pre => D'Length > 2
                 and then (D (D'First) = 'P'
                           or else
                          (D (D'First) = '-' and then D (D'First + 1) = 'P'));
   --  Returns the XSD_Duration given an string encoded time

   ----------------------------------
   -- Basic_8bit string conversion --
   ----------------------------------

   function To_Utf8 (Str : String) return String with Inline;
   function To_Utf8 (Str : Unbounded_String) return Unbounded_String;
   --  Convert the Basic_8bit encoded Str string to Utf-8

   subtype Unicode_Char is Unicode.Unicode_Char;

   type Utf8_Map_Callback is
     not null access function (C : Unicode_Char) return Character;

   function Default_Utf8_Mapping (C : Unicode_Char) return Character;
   --  The default maping replace all invalid character to question mark

   procedure Set_Utf8_Map (Callback : Utf8_Map_Callback);
   --  Callback is the Unicode to 8bit character conversion routine. By
   --  default all characters outside the character range are converted to
   --  question mark. This routine can be used to put in place some
   --  equivalences and is used by From_Utf8 below.

   function From_Utf8 (Str : String) return String with Inline;
   function From_Utf8 (Str : Unbounded_String) return Unbounded_String;
   function From_Utf8 (Str : String) return String_Access;
   --  Convert the Utf-8 encoded Str string to Basic_8bit

   -------------------------------
   --  SOAP Callback translator --
   -------------------------------

   generic
      with function SOAP_CB
        (SOAPAction : String;
         Payload    : Message.Payload.Object;
         Request    : AWS.Status.Data) return AWS.Response.Data;
   function SOAP_Wrapper
     (Request : AWS.Status.Data;
      Schema  : WSDL.Schema.Definition := WSDL.Schema.Empty)
      return AWS.Response.Data;
   --  From a standard HTTP callback calls the SOAP callback passed as generic
   --  formal procedure. Raises Constraint_Error if Request is not a SOAP
   --  request.

   ------------------------------------
   -- SOAP Generator Runtime Support --
   ------------------------------------

   subtype SOAP_Base64 is String;

   generic
      type T is private;
      type T_Array is array (Positive range <>) of T;
      with function Get (O : Types.Object'Class) return T;
   function To_T_Array (From : Types.Object_Set) return T_Array;
   --  Convert a Types.Object_Set to an array of T

   generic
      with package Vector is new Ada.Containers.Vectors
        (Positive, others => <>);
      with function Get (O : Types.Object'Class) return Vector.Element_Type;
   function To_Vector (From : Types.Object_Set) return Vector.Vector;
   --  Convert a Types.Object_Set to an vector

   generic
      type T is private;
      type Index is range <>;
      type T_Array is array (Index) of T;
      with function Get (O : Types.Object'Class) return T;
   function To_T_Array_C (From : Types.Object_Set) return T_Array;
   --  As above but for constrained arrays

   generic
      type T is private;
      type T_Array is array (Positive range <>) of T;
      type XSD_Type is new Types.Object with private;
      E_Name    : String;
      Type_Name : String;
      with function
        Get (V         : T;
             Name      : String := "item";
             Type_Name : String := "";
             NS        : Name_Space.Object := Name_Space.No_Name_Space)
             return XSD_Type;
   function To_Object_Set
     (From : T_Array;
      NS   : Name_Space.Object) return Types.Object_Set;
   --  Convert an array of T to a Types.Object_Set

   generic
      type T is private;
      type Index is range <>;
      type T_Array is array (Index) of T;
      type XSD_Type is new Types.Object with private;
      E_Name    : String;
      Type_Name : String;
      with function
        Get (V         : T;
             Name      : String := "item";
             Type_Name : String := "";
             NS        : Name_Space.Object := Name_Space.No_Name_Space)
             return XSD_Type;
   function To_Object_Set_C
     (From : T_Array;
      NS   : Name_Space.Object) return Types.Object_Set;
   --  As above but for constrained arrays

   generic
      with package Vector is new Ada.Containers.Vectors
        (Positive, others => <>);
      type XSD_Type is new Types.Object with private;
      E_Name    : String;
      Type_Name : String;
      with function
        Get (V         : Vector.Element_Type;
             Name      : String := "item";
             Type_Name : String := "";
             NS        : Name_Space.Object := Name_Space.No_Name_Space)
             return XSD_Type;
   function To_Object_Set_V
     (From : Vector.Vector;
      NS   : Name_Space.Object) return Types.Object_Set;
   --  Convert a Vector to a Types.Object_Set

   function Get (Item : Types.Object'Class) return Unbounded_String;
   --  Returns an Unbounded_String for Item. Item must be a SOAP string object

   function Get (Item : Types.Object'Class) return Character;
   --  Returns a Character for Item. Item must be a SOAP string object

   function Get (Item : Types.Object'Class) return String;
   --  Returns the string representation for enumeration Item

   function V (O : Types.XSD_String) return Unbounded_String;
   --  Returns the Unbounded_String representation for the SOAP string
   --  parameter.

   function V (O : Types.XSD_String) return Character;
   --  Returns the character representation for the SOAP string
   --  parameter. This is supposed to be a string with a single character
   --  to map to Ada type.

   function Any
     (V         : Types.XSD_Any_Type;
      Name      : String := "item";
      Type_Name : String := Types.XML_String;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return Types.XSD_Any_Type;
   --  Return V with the given name

   function AnyURI
     (V         : Unbounded_String;
      Name      : String := "item";
      Type_Name : String := Types.XML_Any_URI;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return Types.XSD_Any_URI;

   function US
     (V         : Unbounded_String;
      Name      : String := "item";
      Type_Name : String := Types.XML_String;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return Types.XSD_String;
   --  Returns the SOAP string for the given Unbounded_String value and name

   function C
     (V         : Character;
      Name      : String := "item";
      Type_Name : String := "Character";
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return Types.XSD_String;
   --  Returns the SOAP string for the given Character value and name

   --  To_SOAP_Object

   function To_SOAP_Object
     (V         : Character;
      Name      : String := "item";
      Type_Name : String := "Character";
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_String
      renames C;

   function To_SOAP_Object
     (V         : SOAP.Types.Object'Class;
      Name      : String := "item";
      Type_Name : String := "";
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Any_Type
      renames SOAP.Types.Any;

   function To_SOAP_Object
     (V         : Types.XSD_Any_Type;
      Name      : String := "item";
      Type_Name : String := "";
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Any_Type
      renames Any;

   function To_SOAP_Object
     (V         : String;
      Name      : String := "item";
      Type_Name : String := "";
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Any_URI
      renames SOAP.Types.AnyURI;

   function To_SOAP_Object
     (V         : String;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Base64;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.SOAP_Base64
      renames SOAP.Types.B64;

   function To_SOAP_Object
     (V         : Boolean;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Boolean;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Boolean
      renames SOAP.Types.B;

   function To_SOAP_Object
     (V         : SOAP.Types.Byte;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Byte;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Byte
      renames SOAP.Types.B;

   function To_SOAP_Object
     (V         : Long_Float;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Double;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Double
      renames SOAP.Types.D;

   function To_SOAP_Object
     (V         : SOAP.Types.Decimal;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Decimal;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Decimal
      renames SOAP.Types.D;

   function To_SOAP_Object
     (V         : Float;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Float;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Float
      renames SOAP.Types.F;

   function To_SOAP_Object
     (V         : Integer;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Int;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Int
      renames SOAP.Types.I;

   function To_SOAP_Object
     (V         : SOAP.Types.Big_Integer;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Integer;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Integer
      renames SOAP.Types.BI;

   function To_SOAP_Object
     (V         : SOAP.Types.Long;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Long;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Long
      renames SOAP.Types.L;

   function To_SOAP_Object
     (V         : SOAP.Types.Short;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Short;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Short
      renames SOAP.Types.S;

   function To_SOAP_Object
     (V    : String;
      Name : String      := "item";
      Type_Name : String := SOAP.Types.XML_String;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_String
      renames SOAP.Types.S;

   function To_SOAP_Object
     (V         : Unbounded_String;
      Name      : String  := "item";
      Type_Name : String := SOAP.Types.XML_String;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_String
      renames SOAP.Types.S;

   function To_SOAP_Object
     (V    : String;
      Name : String      := "item";
      Type_Name : String := SOAP.Types.XML_Normalized_String;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Normalized_String
      renames SOAP.Types.NS;

   function To_SOAP_Object
     (V    : String;
      Name : String      := "item";
      Type_Name : String := SOAP.Types.XML_Token;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Token
      renames SOAP.Types.T;

   function To_SOAP_Object
     (V         : SOAP.Types.Local_Date_Time;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Time_Instant;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Time_Instant
      renames SOAP.Types.T;

   function To_SOAP_Object
     (V         : SOAP.Types.Local_Date;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Date;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Date
      renames SOAP.Types.TD;

   function To_SOAP_Object
     (V         : SOAP.Types.Local_Time;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Time;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Time
      renames SOAP.Types.TT;

   function To_SOAP_Object
     (V         : Standard.Duration;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Duration;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Duration
      renames SOAP.Types.D;

   function To_SOAP_Object
     (V         : SOAP.Types.Unsigned_Long;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Unsigned_Long;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Unsigned_Long
      renames SOAP.Types.UL;

   function To_SOAP_Object
     (V         : SOAP.Types.Unsigned_Int;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Unsigned_Int;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Unsigned_Int
      renames SOAP.Types.UI;

   function To_SOAP_Object
     (V         : SOAP.Types.Unsigned_Short;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Unsigned_Short;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Unsigned_Short
      renames SOAP.Types.US;

   function To_SOAP_Object
     (V         : SOAP.Types.Unsigned_Byte;
      Name      : String := "item";
      Type_Name : String := SOAP.Types.XML_Unsigned_Byte;
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.XSD_Unsigned_Byte
      renames SOAP.Types.UB;

   function To_SOAP_Object
     (V         : String;
      Type_Name : String;
      Name      : String := "item";
      NS        : Name_Space.Object := Name_Space.No_Name_Space)
      return SOAP.Types.SOAP_Enumeration
      renames SOAP.Types.E;

end SOAP.Utils;
