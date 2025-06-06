------------------------------------------------------------------------------
--                              Ada Web Server                              --
--                                                                          --
--                      Copyright (C) 2021, AdaCore                         --
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

with AWS.Utils;

package body AWS.HTTP2 is

   --------------------
   -- Exception_Code --
   --------------------

   function Exception_Code (Exception_Message : String) return Error_Codes is
      E : String renames Exception_Message;
   begin
      if E'Length > 3
        and then E (E'First) = '['
        and then E (E'First + 2) = ']'
      then
         return Error_Codes'Val
           (Utils.Hex_Value (String'[E (E'First + 1)]));
      else
         return C_No_Error;
      end if;
   end Exception_Code;

   -----------------------
   -- Exception_Message --
   -----------------------

   function Exception_Message
     (Error : Error_Codes; Message : String) return String
   is
      Code : constant Natural := Error_Codes'Pos (Error);
   begin
      pragma Assert (Code < 16);
      return '[' & Utils.Hex (Code) & "] " & Message;
   end Exception_Message;

end AWS.HTTP2;
