------------------------------------------------------------------------------
--                              Ada Web Server                              --
--                                                                          --
--                     Copyright (C) 2004-2009, AdaCore                     --
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

package body AWS.Services.Split_Pages.Uniform.Overlapping is

   ---------------------
   -- Get_Page_Ranges --
   ---------------------

   overriding function Get_Page_Ranges
     (This  : Splitter;
      Table : Templates.Translate_Set)
      return Ranges_Table
   is
      Result : Ranges_Table
        := Get_Page_Ranges (Uniform.Splitter (This), Table);
   begin
      for I in Result'First + 1 .. Result'Last loop
         Result (I).First := Integer'Max (Result (I).First - This.Overlap, 1);
      end loop;
      return Result;
   end Get_Page_Ranges;

end AWS.Services.Split_Pages.Uniform.Overlapping;