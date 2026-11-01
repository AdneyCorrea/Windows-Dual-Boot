# DualBoot

Mídia de instalação que reúne Windows 10 e Windows 11 e automatiza a preparação do computador, a instalação do sistema e parte das configurações do primeiro início.

O instalador tem uma interface em PowerShell executada dentro do Windows PE (WinPE). A versão do Windows é escolhida pelo script: com TPM 2.0 detectado, instala Windows 11; sem essa confirmação, instala Windows 10. Essa regra não verifica todos os requisitos de compatibilidade do Windows 11.

Apesar do nome, o fluxo atual instala um sistema por vez. Ele não cria um menu para alternar entre dois Windows instalados no mesmo computador.

## Como a instalação funciona

Ao iniciar o computador pelo pendrive, o ambiente de instalação é carregado de `sources/boot.wim`. Esse arquivo é personalizado para executar um comando que chama `Script/LaunchInstall_UI.ps1` na mídia.

O `LaunchInstall_UI.ps1` localiza as pastas `Win10` e `Win11`, identifica o hardware e determina o disco de destino. Antes de alterar as partições, faz verificações para impedir, entre outros casos, que a própria mídia de instalação seja apagada.

Depois de escolher o Windows, o script prepara as partições para UEFI ou BIOS, aplica a imagem `install.esd` com o DISM e cria os arquivos de boot. Também copia os scripts e o arquivo de respostas correspondente ao sistema escolhido.

Na conclusão da instalação, o `SetupComplete.cmd` prepara os arquivos de personalização e os utilitários. No primeiro logon, as configurações do arquivo de respostas acionam o controlador de atualização de drivers.

**A instalação limpa e formata o disco de destino. Faça backup dos dados antes de iniciar pela mídia.**

## Estrutura do projeto

Os principais arquivos e diretórios são:

```text
DualBoot/
├── boot/                         Arquivos de inicialização BIOS
├── efi/                          Arquivos de inicialização UEFI
├── sources/
│   └── boot.wim                  WinPE personalizado (não incluído no Git)
├── Win10/
│   ├── setup.exe
│   └── sources/
│       └── install.esd           Imagem do Windows 10 (não incluída no Git)
├── Win11/
│   ├── setup.exe
│   └── sources/
│       └── install.esd           Imagem do Windows 11 (não incluída no Git)
├── Script/
│   ├── LaunchInstall_UI.ps1       Interface e fluxo da instalação
│   ├── Drivers/                  Atualização de drivers e primeiro logon
│   ├── Controle de Qualidade/    Ferramenta de verificação do computador
│   ├── Branding/                 Imagens de personalização
│   ├── Wallpaper/                Papel de parede e slideshow
│   ├── Instalador/               Recursos visuais do instalador
│   ├── Utilitarios/              Ferramentas auxiliares
│   └── pci.ids                   Base de identificação de dispositivos PCI
├── autounattend-win10.xml        Respostas automatizadas do Windows 10
├── autounattend-win11.xml        Respostas automatizadas do Windows 11
├── SetupComplete.cmd            Preparação ao concluir a instalação
└── setup.exe
```

A árvore mostra os componentes principais. Preserve também os demais arquivos e pastas da mídia original.

Os caminhos são relativos à raiz da mídia. Não é necessário usar `C:\[2] Projetos\DualBoot`, mas os nomes das pastas e a posição dos arquivos devem ser mantidos, pois os scripts usam essa organização para encontrá-los.

## Arquivos que precisam ser adicionados

Três arquivos ficaram fora do repositório por causa do tamanho e estão previstos no `.gitignore`:

- `Win10/sources/install.esd`
- `Win11/sources/install.esd`
- `sources/boot.wim`

Depois de clonar ou baixar o projeto, coloque cada arquivo exatamente no caminho indicado. O `boot.wim` precisa ser a versão personalizada para este projeto, com suporte ao PowerShell e à interface gráfica e com a chamada para `Script/LaunchInstall_UI.ps1`. Um `boot.wim` comum não fará essa chamada automaticamente.

Para obter o pacote completo, com os três arquivos, entre em contato com o criador: **[Adney Correa](https://github.com/AdneyCorrea)**.

## Uso

Com os arquivos adicionados e a estrutura preservada, coloque o conteúdo em uma mídia preparada para boot e inicie o computador por ela. Apenas copiar a pasta para um pendrive não garante que ele seja inicializável.

O instalador executa a partir do WinPE. Não execute `LaunchInstall_UI.ps1` ou `SetupComplete.cmd` no seu Windows de uso diário para testar o projeto.

## Licença

[GNU GPL v3.0](LICENSE).
