# Model

| | |
|---|---|
| Model | `${{ values.modelId }}` |
| Chosen by | ${{ values.modelSource }} |
| Endpoint | `https://maas.${{ values.appsDomain }}/maas-models/${{ values.modelId }}/v1` (OpenAI compatible) |
| Access | Models-as-a-Service: an API key per application, token quota per subscription |

The model is served by **OpenShift AI** and published through the platform's
**Models-as-a-Service** gateway. Developer Hub lists every served model in the **AI Catalog**
(`/ai-catalog`), with its model card from the OpenShift AI model catalog.

## API key

```bash
oc create secret generic llm-credentials -n ${{ values.name }} \
  --from-literal=LLM_API_KEY=<MaaS API key: OpenShift AI > Gen AI studio > API keys>
oc rollout restart deployment/${{ values.name }} -n ${{ values.name }}
```

## Another model

`LLM_BASE_URL`, `LLM_MODEL` and `LLM_API_KEY` override the defaults of
`src/main/resources/application.properties` per environment, for example in the
`llm-credentials` secret.
