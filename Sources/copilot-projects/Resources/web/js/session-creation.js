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
