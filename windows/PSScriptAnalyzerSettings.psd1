# Reglas de PSScriptAnalyzer excluidas a propósito:
#  - PSAvoidUsingWriteHost: son herramientas de consola; desde PS 5.0 Write-Host va al stream de
#    información y la salida real (tickets, log) no depende de él.
#  - PSUseShouldProcessForStateChangingFunctions: funciones internas del script, no cmdlets públicos.
#    El modo de "simulación" es -DryRun, que cubre todos los cambios.
#  - PSAvoidUsingPositionalParameters: helpers internos (Get-Setting, Add-Section) llamados de forma compacta.
@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingPositionalParameters'
    )
}
