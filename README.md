# 🪟 Windows Dual Boot — Instalação Automatizada do Windows

## 🎯 Objetivo do Projeto

O **Windows Dual Boot** é um projeto de automação desenvolvido para simplificar e agilizar o processo de instalação do Windows em computadores.

A proposta é transformar um pendrive de instalação convencional em uma ferramenta capaz de executar etapas da instalação de forma automatizada, reduzindo a necessidade de interação manual durante o processo.

O projeto foi desenvolvido a partir de uma necessidade prática encontrada em processos de manutenção e montagem de computadores: **padronizar a instalação do sistema operacional e reduzir o tempo gasto com tarefas repetitivas**.

Entre os principais objetivos estão:

* Automatizar o processo de instalação do Windows;
* Reduzir a quantidade de interações manuais durante a instalação;
* Utilizar scripts para controlar diferentes etapas do processo;
* Trabalhar com instalações do Windows 10 e Windows 11;
* Automatizar configurações pós-instalação;
* Criar mecanismos de segurança para evitar a formatação acidental do próprio pendrive de instalação;
* Desenvolver uma solução reutilizável para processos de manutenção e montagem de computadores.

---

## ⚙️ Como funciona

A solução utiliza um pendrive preparado com os arquivos de instalação do Windows e scripts responsáveis por controlar o processo.

De forma simplificada, o fluxo consiste em:

```text
Pendrive de instalação
        │
        ▼
Inicialização do ambiente
        │
        ▼
Execução dos scripts
        │
        ▼
Preparação do armazenamento
        │
        ▼
Aplicação/configuração do Windows
        │
        ▼
Configurações automatizadas
        │
        ▼
Windows pronto para utilização
```

Um dos principais cuidados do projeto é impedir que o dispositivo utilizado como mídia de instalação seja identificado incorretamente como o disco destinado à instalação, reduzindo o risco de perda dos arquivos do próprio pendrive.

---

## 🛠️ Tecnologias Utilizadas

### PowerShell

Principal tecnologia utilizada no projeto.

Foi utilizada para desenvolver a lógica de automação, identificação de dispositivos, execução de comandos administrativos e controle das etapas da instalação.

### Batch / CMD

Utilizado para executar comandos e scripts durante determinadas etapas do processo de instalação e configuração.

### Windows Unattended Setup

Foram utilizados arquivos `autounattend.xml` específicos para Windows 10 e Windows 11, permitindo automatizar configurações que normalmente exigiriam interação do usuário.

### DISM

A infraestrutura de implantação do Windows utiliza ferramentas de gerenciamento de imagens para trabalhar diretamente com os arquivos do sistema operacional, possibilitando uma instalação mais controlada e automatizada.

### Git e GitHub

O projeto utiliza Git para controle de versão e GitHub para armazenamento, documentação e acompanhamento do código-fonte.

---

## 📁 Estrutura do Projeto

```text
Windows-Dual-Boot/
│
├── Script/
│   └── Scripts de automação
│
├── SetupComplete.cmd
│
├── autounattend-win10.xml
│
├── autounattend-win11.xml
│
├── LICENSE
│
└── README.md
```

A separação dos scripts e arquivos de configuração permite modificar partes específicas da instalação sem precisar reconstruir toda a solução.

---

## 📚 O que foi aprendido

O desenvolvimento deste projeto proporcionou experiência prática em diferentes áreas da engenharia de software e administração de sistemas.

### Automação de processos

Foi possível compreender como transformar uma sequência de tarefas manuais em um fluxo automatizado utilizando scripts, reduzindo intervenções humanas e tornando o processo mais consistente.

### PowerShell

O projeto permitiu aprofundar conhecimentos em PowerShell, principalmente na execução de comandos administrativos, manipulação de variáveis, identificação de dispositivos e criação de rotinas automatizadas.

### Implantação do Windows

Foi adquirido conhecimento sobre o processo de implantação do Windows, incluindo imagens do sistema, ambientes de instalação, arquivos de resposta e configurações realizadas durante e após a instalação.

### Gerenciamento de armazenamento

Um dos principais desafios foi trabalhar com discos e partições sem comprometer o dispositivo utilizado como mídia de instalação.

Isso exigiu a criação de verificações e regras para reduzir o risco de selecionar o dispositivo incorreto durante a automação.

### Tratamento de erros

Durante o desenvolvimento foram encontrados diferentes comportamentos relacionados a BIOS/UEFI, MBR/GPT, dispositivos de armazenamento e versões do Windows.

A resolução desses problemas proporcionou experiência prática em **debugging, testes e análise de falhas em diferentes ambientes de hardware**.

### Segurança na automação

Um aprendizado importante foi perceber que automatizar uma tarefa destrutiva, como formatação de discos, exige mecanismos de proteção adicionais.

Por isso, o projeto busca validar o ambiente antes de executar operações que possam causar perda de dados.

### Desenvolvimento incremental

O projeto foi desenvolvido de maneira incremental, com testes realizados em diferentes configurações de hardware e ajustes conforme os problemas eram identificados.

Esse processo reforçou a importância de:

* testar hipóteses;
* analisar mensagens de erro;
* modificar uma variável por vez;
* validar alterações;
* documentar problemas encontrados;
* criar soluções pensando em diferentes cenários.

---

## 🚀 Possíveis Evoluções

O projeto permanece aberto para melhorias e novas funcionalidades.

Algumas possibilidades são:

* [x] Melhorar a detecção automática de hardware;
* [x] Aprimorar a seleção entre Windows 10 e Windows 11;
* [x] Adicionar uma interface gráfica ao processo;
* [ ] Melhorar os mecanismos de proteção contra seleção incorreta de discos;
* [ ] Adicionar suporte a mais configurações de BIOS/UEFI;
* [x] Automatizar instalação de drivers;
* [x] Automatizar configurações pós-instalação;
* [ ] Criar logs detalhados de cada etapa;
* [x] Criar diferentes perfis de instalação.

---

## ⚠️ Aviso

Este projeto executa operações administrativas e pode realizar alterações em discos e partições.

**Utilize somente em computadores e dispositivos nos quais você tenha autorização para realizar a instalação.**

Antes de utilizar a automação em um equipamento real, recomenda-se realizar testes e manter cópias de segurança dos dados importantes.

---

## 👨‍💻 Autor

**Adney Correa**

Estudante de Engenharia de Software, com interesse em desenvolvimento de software, automação, hardware, infraestrutura e soluções para manutenção e suporte técnico.

🔗 **GitHub:** [AdneyCorrea](https://github.com/AdneyCorrea)

---

## 📄 Licença

Este projeto está disponível sob a licença **GNU General Public License v3.0 (GPL-3.0)**.
