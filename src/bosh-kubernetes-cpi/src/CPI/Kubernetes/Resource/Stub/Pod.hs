{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}

module CPI.Kubernetes.Resource.Stub.Pod() where

import           Kubernetes.Model.V1.Container          (Container, mkContainer)
import qualified Kubernetes.Model.V1.Container          as Container
import           Kubernetes.Model.V1.DeleteOptions      (mkDeleteOptions)
import           Kubernetes.Model.V1.ObjectMeta         (ObjectMeta)
import qualified Kubernetes.Model.V1.ObjectMeta         as ObjectMeta
import           Kubernetes.Model.V1.Pod                (Pod)
import qualified Kubernetes.Model.V1.Pod                as Pod
import           Kubernetes.Model.V1.PodList            (PodList)
import qualified Kubernetes.Model.V1.PodList            as PodList
import           Kubernetes.Model.V1.PodSpec            (PodSpec)
import qualified Kubernetes.Model.V1.PodSpec            as PodSpec
import           Kubernetes.Model.V1.PodStatus          (PodStatus, mkPodStatus)
import qualified Kubernetes.Model.V1.PodStatus          as PodStatus
import           Kubernetes.Model.V1.SecretVolumeSource (SecretVolumeSource,
                                                         mkSecretVolumeSource)
import qualified Kubernetes.Model.V1.SecretVolumeSource as SecretVolumeSource
import           Kubernetes.Model.V1.Volume             (Volume, mkVolume)
import qualified Kubernetes.Model.V1.Volume             as Volume
import           Kubernetes.Model.V1.VolumeMount        (VolumeMount,
                                                         mkVolumeMount)
import qualified Kubernetes.Model.V1.VolumeMount        as VolumeMount

import           Kubernetes.Api.ApivApi                 (createNamespacedPod,
                                                         deleteNamespacedPod,
                                                         listNamespacedPod,
                                                         readNamespacedPod,
                                                         replaceNamespacedPod)

import qualified Data.ByteString.Lazy.Char8             as ByteString
import           Data.HashMap.Strict                    (HashMap)
import qualified Data.HashMap.Strict                    as HashMap
import           Data.HashSet                           (HashSet)
import qualified Data.HashSet                           as HashSet
import           Data.Hourglass
import           Data.Maybe
import           Data.Monoid
import           Data.Text                              (Text)
import qualified Data.Text                              as Text

import           Control.Exception.Safe
import           Control.Lens
import           Network.HTTP.Types.Status
import           Servant.Client

import           CPI.Kubernetes.Resource.Metadata       (name)
import           CPI.Kubernetes.Resource.Pod

import           Control.Monad.Stub.Console
import           Control.Monad.Stub.StubMonad
import           Control.Monad.Stub.Time
import           Control.Monad.Stub.Wait
import           CPI.Kubernetes.Resource.Stub.State     (HasImages (..),
                                                         HasPods (..),
                                                         HasSecrets (..))

import           Control.Monad
import qualified Control.Monad.State                    as State
import           Control.Monad.Time
import           Control.Monad.Wait

import qualified GHC.Int                                as GHC


instance (MonadThrow m, Monoid w, HasPods s, HasSecrets s, HasImages s, HasWaitCount w, HasTime s, HasTimeline s) => MonadPod (StubT r s w m) where

  createPod namespace pod = do
    let podName = pod ^. name
    pods <- State.gets asPods
    if isJust $ HashMap.lookup (namespace, podName) pods
      then throwM FailureResponse {
          responseStatus = Status {
              statusCode = 409
            , statusMessage = "Conflict"
          }
        , responseContentType = "text/plain"
        , responseBody = "Pod with name '" <> ((ByteString.pack . Text.unpack) podName) <> "' already exists"
      }
      else pure ()
    let defaultServiceAccount :: Pod -> Pod
        defaultServiceAccount pod = let
            volume = Volume.mkVolume "default-token"
                   & Volume.secret .~ Just secretVolume
            secretVolume = mkSecretVolumeSource
                         & SecretVolumeSource.secretName .~ Just "default-token"
            volumeMount = mkVolumeMount "default-token" "/var/run/secrets/kubernetes.io/serviceaccount"
                        & VolumeMount.readOnly .~ Just True
            in pod
             & Pod.spec._Just.PodSpec.serviceAccountName .~ Just "default"
             & Pod.spec._Just.PodSpec.volumes.non [] %~ (\volumes -> volume <| volumes)
             & container.Container.volumeMounts.non [] %~ (\mounts -> volumeMount <| mounts)

    let pod' = defaultServiceAccount pod
             & status.phase ?~ "Pending"
    let pods' = HashMap.insert (namespace, podName) pod' pods
    State.modify $ updatePods pods'
    timestamp <- currentTime
    images <- State.gets asImages
    secrets <- State.gets asSecrets
    State.modify $ withTimeline
                 (\events ->
                   let runningConditions =    All (HashSet.member (pod' ^. container.image) images)
                                           <> All ((\x -> secretNames ^. contains x) `all` secretVolumeNames)
                       secretNames = HashSet.fromList $ secrets ^.. each.name
                       secretVolumeNames = HashSet.fromList $ pod' ^.. Pod.spec._Just.PodSpec.volumes._Just.each.Volume.secret._Just.SecretVolumeSource.secretName._Just
                       running :: s -> s
                       running = withPods $ HashMap.adjust (status.phase ?~ "Running") (namespace, podName)
                       after :: GHC.Int64 -> Elapsed
                       after n = timestamp + (Elapsed $ Seconds n)
                     in
                       if getAll runningConditions
                         then
                           events & at (after 1).anon [] (const False) %~ (\events -> events |> running)
                         else
                           events)
    pure pod'

  listPod namespace = do
    kube <- State.get
    pure undefined

  getPod namespace name = do
    pods <- State.gets asPods
    pure $ HashMap.lookup (namespace, name) pods

  updatePod namespace pod = do
    pods <- State.gets asPods
    State.put undefined
    pure undefined

  deletePod namespace name = do
    timestamp <- currentTime
    State.modify $ withTimeline
                 (\events ->
                   let
                     terminating :: s -> s
                     terminating = withPods $ HashMap.adjust (\pod -> pod & status.phase ?~ "Terminating") (namespace, name)
                     deleted :: s -> s
                     deleted = withPods $ HashMap.delete (namespace, name)
                     after :: GHC.Int64 -> Elapsed
                     after n = timestamp + (Elapsed $ Seconds n)
                     in
                       events & at (after 1).anon [] (const False) %~ (\events -> events |> terminating)
                              & at (after 2).anon [] (const False) %~ (\events -> events |> deleted)
                  )
    pods <- State.gets asPods
    case HashMap.lookup (namespace, name) pods of
      Just pvc -> pure pvc
      Nothing  -> throwM FailureResponse {
          responseStatus = Status {
            statusMessage = "Not Found"
            , statusCode = 404
          }
        , responseContentType = "text/plain"
        , responseBody = ""
      }

  waitForPod message namespace name predicate = waitFor (WaitConfig (Retry 20) (Seconds 1) message) (getPod namespace name) predicate
