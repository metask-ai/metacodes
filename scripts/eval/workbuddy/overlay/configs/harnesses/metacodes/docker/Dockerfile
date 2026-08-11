# The build context is populated by stage_artifacts.py.  No network access and
# no package manager are involved in the split-mount image build.
FROM scratch
COPY artifacts/bin/ /bin/
COPY artifacts/libexec/ /libexec/
COPY artifacts/share/ /share/
