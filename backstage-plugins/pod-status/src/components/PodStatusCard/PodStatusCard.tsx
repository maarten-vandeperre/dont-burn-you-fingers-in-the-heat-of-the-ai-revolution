import React from 'react';
import useAsync from 'react-use/lib/useAsync';
import useInterval from 'react-use/lib/useInterval';
import { useApi, discoveryApiRef, fetchApiRef } from '@backstage/core-plugin-api';
import { useEntity } from '@backstage/plugin-catalog-react';
import {
  InfoCard,
  Table,
  TableColumn,
  StatusOK,
  StatusWarning,
  StatusError,
  StatusPending,
  Progress,
  ResponseErrorPanel,
} from '@backstage/core-components';

type Pod = {
  name: string;
  status: string;
  ready: string;
  restarts: number;
  node: string;
};

// Same annotation the built-in Kubernetes plugin already reads (backstage.io/kubernetes-namespace,
// see stack/developer-hub/catalog-templates/*.yaml) -- this plugin deliberately reuses it instead
// of inventing a second, competing annotation for "which namespace is this".
const NAMESPACE_ANNOTATION = 'backstage.io/kubernetes-namespace';

function statusIcon(status: string) {
  switch (status) {
    case 'Running':
      return <StatusOK />;
    case 'Pending':
      return <StatusPending />;
    case 'Succeeded':
      return <StatusOK />;
    case 'Failed':
      return <StatusError />;
    default:
      return <StatusWarning />;
  }
}

const columns: TableColumn<Pod>[] = [
  { title: 'Pod', field: 'name' },
  {
    title: 'Status',
    field: 'status',
    render: row => (
      <>
        {statusIcon(row.status)} {row.status}
      </>
    ),
  },
  { title: 'Ready', field: 'ready' },
  { title: 'Restarts', field: 'restarts' },
  { title: 'Node', field: 'node' },
];

/**
 * The whole point of this plugin: call our own custom backend (pod-status-backend), not the
 * built-in Kubernetes plugin's proxy -- see backstage-plugins/pod-status-backend and demo 12.
 */
export const PodStatusCard = () => {
  const { entity } = useEntity();
  const namespace = entity.metadata.annotations?.[NAMESPACE_ANNOTATION];
  const discoveryApi = useApi(discoveryApiRef);
  const fetchApi = useApi(fetchApiRef);

  const fetchPods = async (): Promise<Pod[]> => {
    if (!namespace) return [];
    const baseUrl = await discoveryApi.getBaseUrl('pod-status');
    const response = await fetchApi.fetch(`${baseUrl}/${encodeURIComponent(namespace)}`);
    if (!response.ok) {
      throw new Error(`pod-status backend returned ${response.status}`);
    }
    const body = (await response.json()) as { pods: Pod[] };
    return body.pods;
  };

  const { value: pods, loading, error, retry } = useAsync(fetchPods, [namespace]);
  // Poll every 10s so the card reflects pods restarting/crashing without a manual page reload --
  // the same refresh cadence the built-in Topology/Kubernetes tabs use elsewhere in this repo.
  useInterval(retry, 10_000);

  if (!namespace) {
    return (
      <InfoCard title="Pod status">
        No <code>{NAMESPACE_ANNOTATION}</code> annotation on this entity.
      </InfoCard>
    );
  }
  if (loading && !pods) return <Progress />;
  if (error) return <ResponseErrorPanel error={error} />;

  return (
    <InfoCard title={`Pod status: ${namespace}`}>
      <Table
        options={{ search: false, paging: false, padding: 'dense' }}
        columns={columns}
        data={pods ?? []}
      />
    </InfoCard>
  );
};
