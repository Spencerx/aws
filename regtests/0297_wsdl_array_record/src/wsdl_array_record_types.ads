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

with Ada.Containers.Vectors;
with SOAP.Utils;

package WSDL_Array_Record_Types is

   type Enumeration_Type is (First, Second, Third);

   type Sub_Record_Type is record
      Value : Enumeration_Type;
   end record;

   package Sub_Record_List_Type_Pkg is
     new Ada.Containers.Vectors (Positive, Sub_Record_Type);

   type Enumeration_Record_Type is record
      Value : Enumeration_Type;
      List  : Sub_Record_List_Type_Pkg.Vector;
   end record;

end WSDL_Array_Record_Types;
