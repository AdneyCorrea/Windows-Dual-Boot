# DualBoot — mídia de instalação Windows 10 e Windows 11

Projeto de mídia inicializável com interface gráfica em PowerShell para automatizar a instalação do Windows 10 ou Windows 11, preparar o disco e executar configurações após a instalação.

O nome DualBoot se refere à mídia que reúne as duas versões do Windows. O fluxo atual instala uma delas conforme o hardware detectado; não configura os dois sistemas lado a lado no computador.

## Como funciona

1. O computador inicia pela mídia de instalação e carrega o ambiente Windows PE (WinPE) contido em `sources/boot.wim`.
2. O `boot.wim` personalizado contém a configuração de inicialização que executa um comando para chamar `Script/LaunchInstall_UI.ps1` na mídia.
3. O script localiza a raiz da mídia pelas pastas `Win10` e `Win11`, apresenta a interface gráfica e valida o hardware e o disco de destino.
4. A lógica atual seleciona Windows 11 quando comprova a presença de TPM 2.0. Caso contrário, seleciona Windows 10. Essa escolha faz parte da lógica do projeto e não representa uma verificação completa de todos os requisitos de compatibilidade do Windows.
5. O instalador prepara as partições conforme o modo de inicialização, aplica a imagem do Windows usando DISM, copia os arquivos de configuração e os scripts e configura o boot do sistema instalado.
6. Os arquivos `autounattend-win10.xml` e `autounattend-win11.xml` fornecem as configurações automatizadas de cada versão. O `SetupComplete.cmd` prepara personalizações e utilitários; as configurações de primeiro logon acionam o controlador de atualização de drivers.

**Atenção:** o processo de instalação pode limpar e formatar o disco de destino, apagando os dados existentes. Faça backup e confira o destino antes de utilizar a mídia. Não execute o instalador nem o `SetupComplete.cmd` como um teste no Windows de uso diário.

## Estrutura do projeto

Mantenha os nomes e os caminhos relativos da estrutura original. A árvore abaixo destaca os componentes principais; as demais pastas, arquivos e conteúdos existentes também devem ser preservados.

```text
DualBoot/
├── boot/
├── efi/
├── ProgramData/
├── Script/
│   ├── LaunchInstall_UI.ps1
│   ├── Branding/
│   ├── Controle de Qualidade/
│   ├── Drivers/
│   ├── Instalador/
│   ├── Utilitarios/
│   ├── Wallpaper/
│   └── pci.ids
├── sources/
│   └── boot.wim                  [adicionar separadamente]
├── support/
├── Win10/
│   ├── setup.exe
│   └── sources/
│       └── install.esd           [adicionar separadamente]
├── Win11/
│   ├── setup.exe
│   └── sources/
│       └── install.esd           [adicionar separadamente]
├── autounattend-win10.xml
├── autounattend-win11.xml
├── SetupComplete.cmd
├── autorun.inf
├── bootmgr
├── bootmgr.efi
└── setup.exe
```

O caminho `C:\[2] Projetos\DualBoot` é apenas a localização usada no computador de desenvolvimento. Em outro computador ou na mídia inicializável, a pasta pode estar em outro caminho ou letra de unidade; a organização interna precisa permanecer igual.

## Arquivos grandes necessários

Os três arquivos abaixo não são versionados no Git devido ao tamanho. Eles estão listados no `.gitignore` e precisam ser adicionados manualmente nos caminhos exatos:

| Caminho relativo à raiz | Função |
| --- | --- |
| `Win10/sources/install.esd` | Imagem de instalação do Windows 10. |
| `Win11/sources/install.esd` | Imagem de instalação do Windows 11. |
| `sources/boot.wim` | Ambiente WinPE personalizado que inicia o instalador PowerShell do projeto. |

**Somente baixar ou clonar este repositório não fornece a mídia completa pronta para uso.** É necessário adicionar os três arquivos e manter os demais componentes da estrutura original.

O nome correto do arquivo de inicialização é **`boot.wim`**. Uma imagem `boot.wim` comum, sem a personalização deste projeto, não inicia automaticamente a interface. Ela precisa conter a configuração que localiza a mídia e chama `Script/LaunchInstall_UI.ps1`, além dos componentes necessários para executar o script e sua interface gráfica no WinPE.

## Como utilizar

1. Baixe ou clone o repositório.
2. Adicione os três arquivos ausentes nas pastas indicadas acima.
3. Preserve toda a estrutura e utilize uma mídia preparada para inicialização, compatível com o modo de boot do computador. Copiar a pasta do repositório, por si só, não prepara um pendrive inicializável.
4. Inicie o computador pela mídia para carregar o WinPE personalizado e a interface do instalador.
5. Acompanhe o fluxo de instalação e as etapas de configuração do primeiro início do Windows.

## Versão completa e contato

Para obter o pacote completo do projeto, incluindo os três arquivos grandes que não estão neste repositório (`Win10/sources/install.esd`, `Win11/sources/install.esd` e `sources/boot.wim`), **entre em contato com o criador e mantenedor deste projeto pelo perfil do proprietário do repositório no GitHub**.

O pacote completo deve preservar a mesma estrutura de diretórios apresentada neste README.
