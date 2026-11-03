#!/usr/bin/env bash

printf '\n\n\n\n'
printf '%s\n' \
  '#######################################################' \
  '##################### Infra setup #####################' \
  '#######################################################'
printf '\n\n\n\n'

./deploy.sh stack

printf '\n\n\n\n'
printf '%s\n' \
  '#######################################################' \
  '###################### App setup ######################' \
  '#######################################################'
printf '\n\n\n\n'

./deploy.sh app all

printf '\n\n\n\n'
printf '%s\n' \
  '#######################################################' \
  '############# Developer Lightspeed setup ##############' \
  '#######################################################'
printf '\n\n\n\n'

./deploy.sh lightspeed setup # export OPENAI_API_KEY first to also offer OpenAI in the model picker

printf '\n\n\n\n'
printf '%s\n' \
  '#######################################################' \
  '##################### TSSC setup ######################' \
  '#######################################################'
printf '\n\n\n\n'

./deploy.sh tssc setup --tpa-importers # add --tpa-importers for vulnerability data (hours to import)
