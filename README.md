# Windows-Dual-Boot

Projeto para preparar um pendrive de instalação do Windows com suporte a **Windows 10** e **Windows 11**, usando arquivos de resposta, scripts de automação e estrutura organizada para pós-instalação.

## Objetivo

Este projeto foi criado para facilitar a preparação de um pendrive de instalação personalizado, permitindo uma instalação mais prática e padronizada do Windows.

A proposta é manter no pendrive:

- arquivos de resposta para instalação automática
- scripts auxiliares
- rotina de pós-instalação
- estrutura pronta para uso em diferentes máquinas

## Como o pendrive DualBoot funciona

O funcionamento do pendrive é baseado em uma estrutura onde os arquivos principais do Windows ficam no pendrive junto com os arquivos deste projeto.

De forma resumida, o fluxo é:

1. O pendrive é preparado com os arquivos de instalação do Windows.
2. Os arquivos deste projeto são copiados para a estrutura do pendrive.
3. Os arquivos `autounattend` são usados para automatizar a instalação.
4. O `SetupComplete.cmd` e os scripts da pasta `Script` permitem executar ações adicionais após a instalação.
5. O pendrive pode ser usado como base para instalação padronizada de diferentes máquinas.

## Estrutura esperada do pendrive

A estrutura deve ficar organizada de forma semelhante a esta:

```text
PENDRIVE:\
│   autounattend-win10.xml
│   autounattend-win11.xml
│   SetupComplete.cmd
│   README.md
│
├── Script\
│   ├── (scripts .cmd, .bat e .ps1 do projeto)
│   └── ...
│
├── sources\
│   └── (arquivos da instalação do Windows)
│
└── DriversRepo\
    ├── Intel\
    ├── AMD\
    ├── NVIDIA\
    └── Outros\