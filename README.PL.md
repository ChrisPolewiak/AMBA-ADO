# Azure Monitor Baseline Alerts (AMBA-ALZ)

[English](README.md) | **Polski**

Wdrożenie [AMBA-ALZ](https://azure.github.io/azure-monitor-baseline-alerts/) z Azure DevOps lub z linii poleceń.
Szablon AMBA pochodzi z oficjalnego release'u (bez forka). W repo są tylko konfiguracja, pipeline'y i skrypty.

Pipeline'y uruchamiają skrypty z `bin/`. Podgląd nie zmienia zasobów Azure:
ARM What-If dla init/deploy/services, plan wywołań dla remediacji i natywny PowerShell WhatIf dla cleanup.

## Etapy

| Krok | Cel | Pipeline |
| --- | --- | --- |
| 0 | Tożsamość pipeline'u i Service Connection | Konfiguracja ręczna poniżej |
| 1 | **init**: RG, tożsamość BYO i Monitoring Reader | [amba_init.yml](.pipelines/amba_init.yml) |
| 2 | **deploy**: oficjalne AMBA-ALZ i uprawnienia operatora BYO | [amba_deploy.yml](.pipelines/amba_deploy.yml) |
| 3 | **services**: wybrane polityki usług i assignmenty | [amba_services.yml](.pipelines/amba_services.yml) |
| 4 | **remediate**: zadania remediacji dla istniejących zasobów | [amba_remediate.yml](.pipelines/amba_remediate.yml) |
| 5 | **cleanup**: usunięcie wybranych zasobów AMBA | [amba_cleanup.yml](.pipelines/amba_cleanup.yml) |

## Wymagania

- Init/deploy/services: Azure CLI z Bicep, `jq`, `yq` (mikefarah v4), Bash; services wymaga też Git.
- Remediate/cleanup: PowerShell 7, `yq`, `Az.Accounts`, `Az.Resources`; cleanup dodatkowo `Az.ResourceGraph` i `Az.ManagedServiceIdentity` w wersjach wymaganych przez oficjalne skrypty. Pipeline loguje przez `AzurePowerShell@5`; lokalnie wymagane jest logowanie Azure PowerShell.
- Subskrypcja **Management** i istniejąca hierarchia grup zarządzania (MG) z pseudo root MG.
- Resource providers w subskrypcjach objętych monitoringiem: `Microsoft.AlertsManagement`, `Microsoft.Insights`.

## Konfiguracja

| Plik | Co ustawiasz |
| --- | --- |
| `configuration/ado-env.yml` | Pula agentów (`devops_runner_pool_name`) i Service Connection (`devops_service_connection_name`). |
| `configuration/alzArm.param.json` | Parametry AMBA. Init czyta z niego subskrypcję Management, region, nazwę UAMI (`userAssignedManagedIdentityName`) i `enterpriseScaleCompanyPrefix`. |
| `configuration/amba.yaml` | `init`: nazwa RG tożsamości, lock, tagi i role dla UAMI, opcjonalnie `pseudoRootManagementGroupId`. `deploy`: tag release'u AMBA i nazwa wdrożenia. `services`: grupy zarządzania dla polityk usług. `remediate`: ustawienia opcjonalne. |
| `configuration/services.yaml` | Lista dodatkowych usług Azure (`enabled: true/false`) dla kroku 3, z opcjonalnymi ustawieniami per usługa. |

Nazwa UAMI jest w `alzArm.param.json`, a RG, w którym powstaje, w `amba.yaml`.

Każdy plik ma przykład z wartościami zastępczymi: `ado-env.example.yml`, `alzArm.param.example.json`, `amba.example.yaml`, `services.example.yaml`. Dla nowego środowiska skopiuj przykłady na właściwe pliki (bez `.example`) i podmień wartości zastępcze.

## Dwie tożsamości: nie myl ich

| | Tożsamość pipeline'u | Tożsamość AMBA |
| --- | --- | --- |
| Do czego | Wdraża: uruchamia init, deploy, remediate, cleanup | Używana przez reguły alertów log-search AMBA w czasie działania do odczytu danych (Azure Resource Graph: tagi, nadpisania progów) |
| Kto tworzy | Ty, ręcznie (krok 0) | Krok init |
| Uprawnienia | Zapis: Contributor, Locks Contributor, RBAC Administrator (z warunkiem), role polityk | Tylko odczyt: **Monitoring Reader** na pseudo root MG |
| Gdzie jest używana | Service Connection w Azure DevOps | `bringYourOwnUserAssignedManagedIdentityResourceId` w `alzArm.param.json` |
| Cleanup | Poza zakresem sprzątania AMBA; bez tagu `_deployed_by_amba` | Pełny cleanup może wybrać oznaczone UAMI; adapter blokuje wykonanie, gdy skonfigurowana tożsamość BYO jest oznaczona |

Trzymaj je osobno. Tożsamość AMBA jest podpięta do wielu reguł alertów we wszystkich subskrypcjach, więc musi pozostać tylko do odczytu. Gdyby była nią tożsamość pipeline'u, każda reguła alertu działałaby z prawami do wdrażania zasobów i nadawania ról. Tożsamość pipeline'u musi też istnieć przed init i przetrwać cleanup.

## Krok 0: tożsamość pipeline'u i Service Connection

To jedyny krok ręczny. Pipeline loguje się do Azure jako **UAMI** z federacją (Workload Identity Federation), bez sekretów.
To inna tożsamość niż UAMI z kroku init (tamta służy alertom AMBA). Utwórz ją poza RG z `amba.yaml`.

### 0.1 Utwórz UAMI

```bash
az identity create -g <rg-platform> -n id-pipeline-amba-001 -l <region> --subscription <subskrypcja>
az identity show   -g <rg-platform> -n id-pipeline-amba-001 --query "{principalId:principalId, clientId:clientId, tenantId:tenantId}" -o json
```

### 0.2 Nadaj uprawnienia

Zakres **MG** to pseudo root MG (`enterpriseScaleCompanyPrefix`). Zakres **Root MG** to Tenant Root Group (jego ID to Tenant ID).

| Rola | Zakres | Do czego | Krok |
| --- | --- | --- | --- |
| Contributor | subskrypcja Management | RG, deploymenty, What-If | init |
| Locks Contributor | subskrypcja Management | lock na RG tożsamości | init, cleanup |
| Role Based Access Control Administrator **z warunkiem** | MG | nadawanie ról tożsamościom AMBA | init, deploy, cleanup |
| Monitoring Policy Contributor | MG | polityki AMBA | deploy, cleanup |
| Resource Policy Contributor | Root MG | definicje i assignmenty polityk AMBA, remediacja | deploy, remediate |

Warunek przy RBAC Administrator blokuje nadawanie ról Owner, User Access Administrator i RBAC Administrator, więc pipeline nie podniesie sobie uprawnień.
Do samego kroku init wystarczą trzy pierwsze role.

```bash
PRINCIPAL_ID=<principalId z 0.1>
MG_ID=<pseudo root MG>
MG_SCOPE="/providers/Microsoft.Management/managementGroups/$MG_ID"
ROOT_MG_SCOPE="/providers/Microsoft.Management/managementGroups/<Tenant ID>"
SUB_SCOPE="/subscriptions/<managementSubscriptionId>"

az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Contributor" --scope "$SUB_SCOPE"
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Locks Contributor" --scope "$SUB_SCOPE"
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Monitoring Policy Contributor" --scope "$MG_SCOPE"
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Resource Policy Contributor" --scope "$ROOT_MG_SCOPE"

# RBAC Administrator z warunkiem (bez Owner, User Access Administrator, RBAC Administrator)
CONDITION=$(cat <<'COND'
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, f58310d9-a9f6-439a-9e8d-f62e7b41a168})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, f58310d9-a9f6-439a-9e8d-f62e7b41a168}))
COND
)
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Role Based Access Control Administrator" --scope "$MG_SCOPE" \
  --condition "$CONDITION" --condition-version "2.0"
```

Role może nadać osoba z uprawnieniem do przypisywania ról na tych zakresach (np. Owner lub User Access Administrator).

### 0.3 Service Connection w Azure DevOps

1. Project settings → Service connections → New service connection → **Azure Resource Manager**.
2. Wybierz **Workload Identity federation (manual)** z istniejącą tożsamością.
3. Podaj ID i nazwę subskrypcji Management, Tenant ID i **Service Principal Id = `clientId`** z 0.1.
4. Kreator pokaże **Issuer** i **Subject**. Dodaj je jako poświadczenie federacyjne:

```bash
az identity federated-credential create \
  --name ado-amba --identity-name id-pipeline-amba-001 --resource-group <rg-platform> \
  --issuer "<Issuer z kreatora>" --subject "<Subject z kreatora>" \
  --audiences api://AzureADTokenExchange
```

5. W kreatorze wybierz **Verify and save**.
6. Wpisz nazwę Service Connection i nazwę puli agentów w `configuration/ado-env.yml`.

## Krok 1: init

Init tworzy:

- resource group z `configuration/amba.yaml` z lockiem `CanNotDelete`,
- UAMI o nazwie z `alzArm.param.json`,
- rolę **Monitoring Reader** dla tego UAMI na pseudo root MG (alerty log-search czytają przez nią Azure Resource Graph).

Init można uruchamiać wielokrotnie.

### W Azure DevOps

1. Pipelines → New pipeline → Azure Repos Git → Existing Azure Pipelines YAML file → `/.pipelines/amba_init.yml` (np. nazwa `AMBA-1-init`).
2. Uruchom z `deployMode = whatif` (domyślnie). Podgląd jest w logu i w załączniku `WhatIfOutput.txt`.
3. Uruchom ponownie z `deployMode = deploy`. Pipeline najpierw pokaże podgląd, potem wdroży. Jeśli podgląd się nie uda, wdrożenie nie ruszy.

### Poza Azure DevOps

```bash
az login
./bin/amba_init.sh -deployMode lint     # sprawdzenie szablonów Bicep
./bin/amba_init.sh -deployMode whatif   # podgląd
./bin/amba_init.sh -deployMode deploy   # wdrożenie
```

Inny plik parametrów lub konfiguracji podasz zmiennymi `AMBA_PARAM_FILE` i `AMBA_CONFIG_FILE`.

### Po init

Skrypt wypisuje wartości do wpisania w `configuration/alzArm.param.json`:

```bash
bringYourOwnUserAssignedManagedIdentity           = Yes
bringYourOwnUserAssignedManagedIdentityResourceId = /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<nazwa>
```

Jeśli plik ma inne wartości, skrypt zgłosi ostrzeżenie.

## Krok 2: deploy

| Ustawienie wdrożenia | Wartość |
| --- | --- |
| Szablon | Oficjalny zdalny `patterns/alz/alzArm.json` |
| Wersja | `deploy.releaseTag` w `configuration/amba.yaml`; dla powtarzalności stały release/commit, nie ruchome `main` |
| Zakres | Pseudo root MG |
| Parametry | `configuration/alzArm.param.json` |

Wymagania:

- init został uruchomiony, a w `alzArm.param.json` jest `bringYourOwnUserAssignedManagedIdentity = Yes` i Resource ID tożsamości AMBA,
- w `alzArm.param.json` są ustawione `managementSubscriptionId` i nazwy grup zarządzania.

Po wdrożeniu AMBA skrypt nadaje rolę **Managed Identity Operator** na tożsamości AMBA assignmentom polityk `Deploy-AMBA-VM`, `Deploy-AMBA-HybridVM`, `Deploy-AMBA-VMSS`, `Deploy-AMBA-Management` i `Deploy-AMBA-Web` (lista w `deploy.managedIdentityOperatorAssignments`).
AMBA robi to sama tylko wtedy, gdy sama tworzy tożsamość, więc przy „bring your own” musi to zrobić pipeline.

Tagi pipeline'u wybierasz w `deploy.pipelineTags`. Zmienne tagi, np. `pipelineBuild`, zmieniają też parametry polityk widoczne w What-If.

What-If pokazuje wdrożenie AMBA. Rola operatora jest w podglądzie tylko wtedy, gdy assignmenty polityk już istnieją (nie przy pierwszym uruchomieniu).

### W Azure DevOps

Utwórz pipeline z `/.pipelines/amba_deploy.yml` (np. `AMBA-2-deploy`) i uruchom jak init: najpierw `whatif`, potem `deploy`.

### Poza Azure DevOps

```bash
./bin/amba_deploy.sh -deployMode whatif
./bin/amba_deploy.sh -deployMode deploy
```

### Aktualizacja AMBA

Zmień `deploy.releaseTag` w `configuration/amba.yaml`, uruchom `whatif` i przejrzyj wynik, potem `deploy`. Release'y: <https://github.com/Azure/azure-monitor-baseline-alerts/releases>

## Krok 3: services (alerty dla dodatkowych usług Azure)

AMBA-ALZ obejmuje stały zestaw usług. Repozytorium AMBA (katalog `services`) ma polityki alertów dla wielu innych, np. Application Gateway z WAF. Krok services wdraża je z tego samego releasu co `deploy`.

1. Otwórz `configuration/services.yaml`. Zawiera listę wszystkich dostępnych usług (najpierw skopiuj `configuration/services.example.yaml`, jeśli pliku nie ma). Każda usługa ma `enabled: false`.
2. Ustaw `enabled: true` dla usług, które chcesz monitorować:

```yaml
services:
  - path: Network/applicationGateways
    enabled: true
```

3. Uruchom `/.pipelines/amba_services.yml` (np. `AMBA-3-services`) najpierw z `whatif`, potem z `deploy`. Albo z linii poleceń: `./bin/amba_services.sh -deployMode whatif`.

Krok używa oficjalnych definicji AMBA. Automatyczne assignmenty, tożsamości i RBAC są integracją tego repozytorium. Przed włączeniem usługi sprawdź zakres i pokrycie alertów przez AMBA-ALZ.
Nazwy wyświetlane assignmentów mają format `AMBA-Services | <oficjalna nazwa wyświetlana>`; nazwy techniczne i oficjalne definicje pozostają bez zmian.

| Ustawienie usługi | Cel |
| --- | --- |
| `path`, `enabled` | Katalog usługi AMBA i wybór do wdrożenia |
| `include`, `exclude` | Nazwy alertów do wyboru lub pominięcia; brak/puste `include` wybiera wszystkie |
| `assignmentManagementGroupId` | Nadpisanie MG assignmentu |
| `parameters`, `overrides` | Parametry polityk usługi lub wskazanego alertu; overrides mają pierwszeństwo |

Przykłady i opis parametrów: [services.example.yaml](configuration/services.example.yaml). Domyślne MG definicji i assignmentów ustawiasz w sekcji `services` w [amba.yaml](configuration/amba.yaml).

Polityki tworzą alerty na istniejących zasobach dopiero po remediacji (krok 4), a na nowych zasobach automatycznie.
Definicje polityk żądają roli **Contributor** dla tożsamości każdego assignmentu; skrypt nadaje ją na MG assignmentu.

Nazwy assignmentów są stałe i mają maksymalnie 24 znaki; czytelne nazwy wyświetlane pochodzą z AMBA.

### Utrzymanie services

| Zadanie | Kroki | Uwaga |
| --- | --- | --- |
| Dodanie usługi | 1. Ustaw dla niej `enabled: true` w `services.yaml`.<br>2. Uruchom **services** (`whatif`, potem `deploy`).<br>3. Uruchom **remediate** (krok 4) dla istniejących zasobów. | Dodawane są wszystkie alerty usługi. |
| Dodanie lub pominięcie pojedynczego alertu | 1. Dopisz nazwę alertu do `include` lub `exclude` usługi.<br>2. Uruchom **services**.<br>3. Przy dodawaniu uruchom **remediate** (krok 4). | Nazwa alertu jak na stronie usługi, np. `AzwafSecRule`. |
| Zmiana severity, okna, progu | 1. Zmień `parameters` (wszystkie alerty usługi) lub `overrides` (jeden alert).<br>2. Uruchom **services**.<br>3. Uruchom **remediate** (krok 4). | Najpierw assignment, potem istniejące reguły alertów. |
| Przejście na nowszy release AMBA | 1. Zmień `deploy.releaseTag`.<br>2. Uruchom **deploy**, potem **services**, potem **remediate**. | Services używa tego samego taga releasu co deploy. Sprawdź listę w `services.yaml` względem katalogu `services` w releasie. |
| Pominięcie alertu lub usługi we wdrożeniu | Ustaw `enabled: false` lub dodaj alert do `exclude`. | Niczego nie usuwa ani nie wyłącza w Azure. Istniejące assignmenty pozostają aktywne; usunięcie ich i reguł alertów to osobna operacja. |

Zawsze zaczynaj od `whatif`. Nazwy assignmentów są w jego wyniku.

## Krok 4: remediate

Polityki tworzą reguły alertów na **nowych** zasobach automatycznie. Dla zasobów, które **już istnieją**, oraz po zmianie tagów lub parametrów uruchom remediację.

1. Uruchom `/.pipelines/amba_remediate.yml` (np. `AMBA-4-remediate`) z `whatif`: pokaże MG i nazwy polityk/initiatives przekazywane do oficjalnego skryptu. Niczego nie tworzy; to plan wywołań, nie natywny WhatIf upstream.
2. Uruchom z `deploy`. Albo z linii poleceń: `./bin/amba_remediate.sh -deployMode deploy`.

| Ustawienie / działanie | Wartość |
| --- | --- |
| Wykonanie | Oficjalny [Start-AMBA-ALZ-Remediation.ps1](bin/upstream/Start-AMBA-ALZ-Remediation.ps1); najpierw notification assets i health initiatives |
| Selekcja | `remediate.assignmentNamePattern` (domyślnie `^(Deploy-AMBA-\|amba-x-)`), `include`, `exclude`, dodatkowe `managementGroups` |
| Zakres | Upstream wybiera po nazwie definicji/initiative; może remediować wiele jej assignmentów na tym scope |
| Zakończenie | Zadania działają dalej w Azure; wyniki w **Azure Policy > Remediation** |
| Zgodność | Bez wymuszania `ReEvaluateCompliance`; zachowanie zadań wynika z oficjalnego skryptu |

Remediation i cleanup korzystają z lokalnych oficjalnych skryptów. Źródło, wymagania wersji i aktualizacja: [bin/upstream](bin/upstream/README.md).

## Krok 5: cleanup

Uruchamia niezmodyfikowany oficjalny `patterns/alz/scripts/Start-AMBA-ALZ-Maintenance.ps1`. Selekcja zasobów i kolejność usuwania wynikają z upstream. Nie oznaczaj tożsamości pipeline'u tagiem `_deployed_by_amba`.

Znacznik `_deployed_by_amba` nie rozróżnia poszczególnych wdrożeń AMBA ani repozytoriów. Zasoby innego wdrożenia z tym samym znacznikiem również mogą zostać wybrane, jeśli są widoczne dla tożsamości uruchamiającej cleanup. Przed usunięciem sprawdź listę `whatif`, szczególnie gdy w środowisku działa kilka wdrożeń AMBA.

1. Uruchom `/.pipelines/amba_cleanup.yml` (np. `AMBA-5-cleanup`) z `whatif` i wybraną oficjalną operacją `cleanItems`. Przekazuje natywne `-WhatIf` do upstream.
2. Uruchom z `deploy` i wybraną pozycją do usunięcia. Albo z linii poleceń: `./bin/amba_cleanup.sh -deployMode deploy -cleanItems Alerts`.

| `cleanItems` | Usuwa |
| --- | --- |
| `Alerts` | reguły alertów (metryczne, log-search, activity log) |
| `OrphanedAlerts` | tylko reguły alertów, których zasób docelowy już nie istnieje |
| `NotificationAssets` | alert processing rules i action groups |
| `PolicyAssignments` | assignmenty initiatives AMBA-ALZ i services |
| `RoleAssignments` | role assignmenty tych assignmentów |
| `PolicyDefinitions` | initiatives i definicje polityk |
| `Deployments` | wdrożenia ARM `amba-*` na pseudo root MG |
| `OldNotificationAssets` | stare notification assets wybierane przez upstream |
| `LegacySH` | stare zasoby Service Health wybierane przez upstream |
| `Amba-Alz` | pełny cleanup upstream, w tym oznaczone UAMI i grupy zasobów |

| Kontrola bezpieczeństwa | Zasada |
| --- | --- |
| Domyślne ustawienia | `Alerts`, `whatif`; przed wykonaniem sprawdź podgląd |
| Pełny cleanup | `Amba-Alz` może usunąć oznaczone UAMI i RG; wykonanie jest blokowane, gdy skonfigurowana tożsamość BYO ma `_deployed_by_amba=True` |
| Locki / nieoznaczone zasoby | Mogą wymagać osobnej obsługi |
| Weryfikacja | Ponów WhatIf po propagacji Resource Graph |
Tożsamość uruchamiająca cleanup potrzebuje więcej niż w pozostałych krokach: roli **Contributor** na grupach zarządzania lub subskrypcjach z zasobami AMBA (do usuwania reguł alertów, action groups i grup zasobów). Contributor zawiera już odczyt, którego potrzebuje wyszukiwanie. Zdejmij ją po cleanup.

### Błędy cleanup

Przed ponowieniem sprawdź błędy zadania, uprawnienia i locki. Service Connection i definicje pipeline'ów są poza zakresem cleanup upstream.

## Zarządzanie monitoringiem przez tagi

Wdrożenie nie zawiera wyjątków. Wyjątki ustawiasz tagami na zasobach:

- **Wyłączenie monitoringu** zasobu lub subskrypcji: tag `MonitorDisable` z wartością `true`, `Test`, `Dev` lub `Sandbox`. Nazwę i wartości zmienisz w `alzArm.param.json` (`ALZMonitorDisableTagName`, `ALZMonitorDisableTagValues`).
- **Inny próg alertu**: tag `_amba-<metricName>-threshold-Override_` z wartością liczbową, np. `_amba-CpuPercentage-threshold-Override_ = 95`. Dotyczy alertów metrycznych i log-search. Log-search bierze nową wartość od razu, alerty metryczne wymagają remediacji.
- Pełna lista: <https://azure.github.io/azure-monitor-baseline-alerts/patterns/alz/HowTo/Threshold-Override/>

### Zmiana konfiguracji po wdrożeniu (tuning)

Zmiana tagu lub parametru nie zmienia istniejących reguł alertów. Reguły tworzą polityki `DeployIfNotExists`, więc zmiana dociera do nich tylko przez poniższe kroki.

| Scenariusz | Kroki | Efekt |
| --- | --- | --- |
| Inny próg, alert **metryczny** (tag override) | 1. Ustaw tag na zasobie.<br>2. Uruchom **remediate** (krok 4) dla polityki tej usługi. | Istniejąca reguła zostaje przekonfigurowana. |
| Wyłączenie alertu wszędzie (`<Typ><Metryka>AlertState = "false"`) | 1. Zmień parametr w `alzArm.param.json`.<br>2. Uruchom **deploy** (krok 2).<br>3. Uruchom **remediate** (krok 4). | Reguły zostają, ale są wyłączone. Żeby włączyć, ustaw `"true"` i powtórz. |
| Zatrzymanie tworzenia danego alertu (`PolicyEffect = disabled`) | 1. Zmień parametr w `alzArm.param.json`.<br>2. Uruchom **deploy** (krok 2). | Nowe reguły się nie tworzą. Istniejące zostają. |
| Wykluczenie zasobu lub subskrypcji (tag `MonitorDisable`) | Ustaw tag; w razie potrzeby osobno przejrzyj i usuń istniejące reguły alertów. | Oficjalny cleanup nie ma operacji `ExcludedAlerts`. Remediacja nie usuwa istniejących reguł. |
| Zmiana parametru polityki we wzorcu (np. severity, okno, częstotliwość, zakres) | 1. Zmień `alzArm.param.json`.<br>2. Uruchom **deploy** (krok 2).<br>3. Uruchom **remediate** (krok 4). | Najpierw polityki, potem istniejące reguły. |
| Start od nowa | 1. Uruchom podgląd **cleanup** (krok 5), pozycja `Alerts` lub `Amba-Alz` (pełny cleanup upstream).<br>2. Po zatwierdzonym cleanup uruchom **deploy** (krok 2), potem **remediate** (krok 4). | Ostateczność. Najpierw sprawdź obsługę tożsamości. Alerty powstają od nowa, historia starych reguł przepada. |

Powiadomienia nie są częścią tego procesu. Reguły alertów AMBA są wdrażane bez powiadomień; Action Groups i Alert Processing Rules tworzysz i zmieniasz osobno w Azure.

Przed `deploy` i `cleanup` zawsze uruchom `whatif`.

## Rozwiązywanie problemów

| Objaw | Co zrobić |
| --- | --- |
| `'yq' is required but was not found` | Zainstaluj `yq` (mikefarah v4) na agencie. |
| `... is not set` | Uzupełnij brakujący parametr w `configuration/alzArm.param.json` lub `configuration/amba.yaml`. |
| What-If kończy się błędem autoryzacji | Sprawdź role z kroku 0.2 (np. Contributor na subskrypcji Management). |
| Błąd przy tworzeniu locka | Brakuje roli Locks Contributor na subskrypcji Management. |
| Nie da się usunąć RG tożsamości | Lock `CanNotDelete`. Zdejmie go krok cleanup albo zrobisz to ręcznie. |
| Po ponownym utworzeniu UAMI znikły jego role | Nowe UAMI ma nowy `principalId`. Uruchom init ponownie, a role zostaną nadane od nowa. |
| Pipeline zatrzymuje się na CheckVariables | W `configuration/ado-env.yml` zostały wartości `CHANGE-ME`. |
