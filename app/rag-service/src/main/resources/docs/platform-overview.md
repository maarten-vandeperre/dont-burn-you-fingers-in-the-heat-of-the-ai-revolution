# Platform overview

The demo platform runs on OpenShift 4.22. OpenShift AI 3.4 provides the AI workloads: model serving with KServe and vLLM, the Gen AI studio playground, MLflow for experiment tracking and Models-as-a-Service for governed access to models.

Around the AI layer the platform installs OpenShift Service Mesh 3 with Kiali, Streams for Apache Kafka with Debezium for change data capture, Red Hat Developer Hub as the developer portal, OpenShift GitOps with Argo CD and Argo Rollouts, and OpenShift Pipelines based on Tekton.

The demo applications live in the ai-demo namespace. The frontend is a Quarkus backend for frontend that serves a React user interface built with Vite and Tailwind. The rag-service answers questions with retrieval augmented generation, the model-router abstracts the language models with Apache Camel, the orders-service writes to PostgreSQL and the projection-service keeps MongoDB in sync through Kafka and Debezium.
