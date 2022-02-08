Add all .NET projects under the Projects folder. Add XML file in the Projects
folder to define which projects to build and the order in which to build them.

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