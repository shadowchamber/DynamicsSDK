Microsoft Dynamics 365 Unified Operations SDK for Developer Application Lifecycle Management.
---------------------------------------------------------------------------------------------
The scripts and tools in the Dynamics SDK are intended for use with building
customization to the Microsoft Dynamics 365 Unified Operations product. They are designed to be
used with an Azure DevOps account from where the build definition can be managed and builds triggered.


Version Control File Structure.
-------------------------------------------------------------------------------
Add all Dynamics 365 X++ customizations under the Metadata folder.

Example tree structure:
$/Project/Trunk/Main/Metadata
+---MyMainModule
|   +---Descriptor
|   |       MyMainModule.xml
|   |
|   +---MyMainModule
|       +---AxClass
|       |       MyClass.xml
|       |
|       \---AxTable
|               MyMainTable.xml
|
\---MyOtherModule
    +---Descriptor
    |       MyOtherModule.xml
    |
    \---MyOtherModule
        \---AxClass
                MyTestClass.xml

If you have any .NET projects to build add them under the Projects folder. Add
XML file in the Projects folder to define which projects to build and the order
in which to build them.

Example tree structure:
$/Project/Trunk/Main/Projects
|   MyProjects.xml
|
+---MyManagedLibrary
|   |   MyClass.cs
|   |   MyManagedLibrary.csproj
|   |
|   \---Properties
|           AssemblyInfo.cs
|
\---MyOtherProject
    |   MyOtherClass.cs
    |   MyOtherProject.csproj
    |
    \---Properties
            AssemblyInfo.cs

Please see https://ax.help.dynamics.com for more details.
