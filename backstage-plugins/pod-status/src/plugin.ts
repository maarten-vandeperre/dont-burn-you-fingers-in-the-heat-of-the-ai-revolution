import { createPlugin, createComponentExtension } from '@backstage/core-plugin-api';

/**
 * The classic Backstage frontend plugin shape (createPlugin + createComponentExtension) -- the
 * same one dynamic-plugins.yaml's existing third-party entries (e.g. backstage-community-plugin-
 * argocd) use under the hood, which is why it maps cleanly onto a dynamic-plugins.yaml
 * `mountPoints` entry once exported (see README.md "5. Wire it into Developer Hub").
 */
export const podStatusPlugin = createPlugin({
  id: 'pod-status',
});

export const EntityPodStatusContent = podStatusPlugin.provide(
  createComponentExtension({
    name: 'EntityPodStatusContent',
    component: {
      lazy: () => import('./components/PodStatusCard').then(m => m.PodStatusCard),
    },
  }),
);
