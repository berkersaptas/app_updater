export function fullAotLibraryAllowedFromEnv(env = process.env) {
  return env.ALLOW_FULL_AOT_LIBRARY === 'true';
}

export function artifactKindAllowed(artifactKind, allowFullAotLibrary) {
  return artifactKind !== 'full_aot_library' || allowFullAotLibrary;
}
