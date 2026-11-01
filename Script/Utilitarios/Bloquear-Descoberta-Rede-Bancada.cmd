@echo off
rem Abre o menu de bloqueio de descoberta de rede da bancada.
rem Duplo clique aqui: o .ps1 aberto direto vai para o Bloco de Notas ou
rem esbarra na politica de execucao. O script pede elevacao sozinho.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Bloquear-Descoberta-Rede-Bancada-Interativo.ps1"
