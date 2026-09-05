function chooseCreateProjectId(projects, currentProjectId, hostSelectedProjectId) {
  const projectIds = new Set(projects.map((project) => project.id));
  if (currentProjectId && projectIds.has(currentProjectId)) {
    return currentProjectId;
  }
  if (hostSelectedProjectId && projectIds.has(hostSelectedProjectId)) {
    return hostSelectedProjectId;
  }
  return projects[0]?.id || null;
}

function createProjectSignature(projects) {
  return JSON.stringify(projects.map((project) => [project.id, project.name]));
}

function createSessionFailureMessage(response) {
  const errorCode = response.headers?.get('X-Copilot-Projects-Error');
  if (response.status === 503) {
    return errorCode === 'persistence-unavailable'
      ? 'Session creation could not be saved — tap to retry'
      : 'Copilot is unavailable — tap to retry';
  }
  return 'Host error — tap New Session to retry';
}
