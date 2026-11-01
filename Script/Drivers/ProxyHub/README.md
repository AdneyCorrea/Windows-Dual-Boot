# Proxy de Hub — ACPI MSFT8000

`DISPOSITIVO DE PROXY HUB.EXE` é o instalador fornecido pelo usuário, movido de `Outros` para esta pasta. A cópia original em `D:\Outros` tinha o mesmo SHA-256:

```text
1A567C820856250859910E9BF1F3F36E2CE29F5B2424C65104E5CBC442FD8249
```

O executável tem assinatura válida de GIGA-BYTE TECHNOLOGY CO., LTD. e contém um pacote 7-Zip SFX configurado com `GUIMode="2"` e `RunProgram="InstUpd.exe"`.

O atualizador chama o executável somente quando encontra pendência do dispositivo `ACPI\VEN_MSFT&DEV_8000` ou seu identificador equivalente `ACPI\MSFT8000`. IDs parecidos de outros dispositivos não disparam a instalação. Um Proxy de Hub já sem erro é ignorado.

Nenhum parâmetro de instalação foi presumido. O script espera o instalador terminar, registra o código de saída, solicita nova detecção PnP e confere se o dispositivo continua pendente. Código zero do instalador não é tratado como prova de que o driver ficou ativo. Um retorno 3010 solicita a confirmação após reiniciar.

No Windows instalado, a cópia fica em `Windows\Setup\Scripts\ProxyHub`. O log é o mesmo do atualizador normal, em `DriversRepo\_Logs`.
